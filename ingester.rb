require "redis"
require "oj"
require "polygonio"
require "pg"
require "sentry-ruby"
require "tzinfo"
require "uri"
require "json"
require "set"
require "time"
require "securerandom"

Sentry.init { |config| config.dsn = ENV["SENTRY_DSN"] }

REDIS_URL    = ENV.fetch("REDIS_URL")
DATABASE_URL = ENV.fetch("DATABASE_URL")
API_KEY      = ENV.fetch("API_KEY")

SIX_DAYS        = 518_400
SAMPLE_INTERVAL = 60
STALE_AFTER     = 120
BACKOFF         = 60
JOIN_TIMEOUT    = 10

TZ = TZInfo::Timezone.get("America/New_York")

DB_URI = URI.parse(DATABASE_URL)

BASE_PG_OPTS = {
  host:     DB_URI.host,
  port:     DB_URI.port || 5432,
  dbname:   DB_URI.path.delete_prefix("/"),
  user:     DB_URI.user     && URI::DEFAULT_PARSER.unescape(DB_URI.user),
  password: DB_URI.password && URI::DEFAULT_PARSER.unescape(DB_URI.password),

  connect_timeout:     2,
  keepalives:          1,
  keepalives_idle:     10,
  keepalives_interval: 5,
  keepalives_count:    3
}.freeze

PG_OPTS = BASE_PG_OPTS.merge(
  options: "-c statement_timeout=2000 -c application_name=ingester"
).freeze

BOOT_PG_OPTS = BASE_PG_OPTS.merge(
  options: "-c statement_timeout=15000 -c application_name=ingester-boot"
).freeze

REDIS_OPTS = {
  url:           REDIS_URL,
  ssl:           true,
  connect_timeout: 5,
  read_timeout:  2,
  write_timeout: 2
}.freeze

INSERT_SAMPLE = <<~SQL.freeze
  INSERT INTO ingester_samples
    (at, boot_id, connection_id, kind, state, cause,
     frames, events, symbols, max_lag_ms, sum_lag_ms, sampled_events,
     last_message_at, first_message_at, detail)
  VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15)
SQL

HOLIDAYS = Set.new(%w[
  2026-01-01 2026-01-19 2026-02-16 2026-04-03 2026-05-25
  2026-06-19 2026-07-03 2026-09-07 2026-11-26 2026-12-25
  2027-01-01 2027-01-18 2027-02-15 2027-03-26 2027-05-31
  2027-06-18 2027-07-05 2027-09-06 2027-11-25 2027-12-24
]).freeze

EARLY_CLOSES = Set.new(%w[
  2026-11-27 2026-12-24
  2027-11-26
]).freeze

State = Struct.new(
  :boot_id, :connection_id, :subscriber, :shutting_down, :backoff,
  :connected_at, :last_message_at, :first_message_at, :last_error,
  :frames, :events, :max_lag_ms, :sum_lag_ms, :sampled_events, :symbols,
  keyword_init: true
)

STATE = State.new(
  boot_id: SecureRandom.uuid,
  shutting_down: false,
  backoff: false,
  frames: 0,
  events: 0,
  max_lag_ms: 0,
  sum_lag_ms: 0,
  sampled_events: 0,
  symbols: Set.new
)

SAMPLE_LOCK = Mutex.new

def fetch_tickers
  db = nil
  db = PG.connect(BOOT_PG_OPTS)
  db.exec('SELECT symbol FROM tickers').map { |row| row['symbol'] }
ensure
  db&.close
end

def market_open?
  now = TZ.now
  return false if now.saturday? || now.sunday?

  date = now.strftime('%Y-%m-%d')
  return false if HOLIDAYS.include?(date)

  close_hour = EARLY_CLOSES.include?(date) ? 13 : 16
  minutes = (now.hour * 60) + now.min
  minutes >= 570 && minutes < close_hour * 60
end

def derive_state
  return 'shutdown'   if STATE.shutting_down
  return 'backoff'    if STATE.backoff
  return 'booting'    if STATE.subscriber.nil?
  return 'dead'       unless STATE.subscriber.alive?

  since = Time.now - (STATE.last_message_at || STATE.connected_at)
  return 'connecting' if STATE.last_message_at.nil? && since <= STALE_AFTER
  return 'idle'       unless market_open?
  return 'stale'      if since > STALE_AFTER

  return 'streaming'
end

def write_sample!(kind = 'tick', cause: nil, detail: nil)
  lag = seen = params = sum = sampled = nil

  SAMPLE_LOCK.synchronize do
    lag    = STATE.max_lag_ms
    sum    = STATE.sum_lag_ms
    sampled = STATE.sampled_events
    seen   = STATE.symbols

    STATE.max_lag_ms    = 0
    STATE.sum_lag_ms    = 0
    STATE.sampled_events = 0
    STATE.symbols       = Set.new

    params = [
      Time.now.utc,
      STATE.boot_id,
      STATE.connection_id,
      kind,
      derive_state,
      cause,
      STATE.frames,
      STATE.events,
      seen.size,
      lag,
      sum,
      sampled,
      STATE.last_message_at,
      STATE.first_message_at,
      detail && JSON.generate(detail)
    ]
  end

  puts JSON.generate(
    at: params[0].iso8601, kind: params[3], state: params[4],
    cause: params[5], boot_id: params[1], connection_id: params[2]
  )

  db = nil
  begin
    db = PG.connect(PG_OPTS)
    db.exec_params(INSERT_SAMPLE, params)
  rescue => e
    SAMPLE_LOCK.synchronize do
      STATE.max_lag_ms     = lag if lag > STATE.max_lag_ms
      STATE.sum_lag_ms    += sum
      STATE.sampled_events += sampled
      STATE.symbols.merge(seen)
    end
    Sentry.capture_exception(e, extra: {
      at: params[0].iso8601,
      boot_id: params[1],
      connection_id: params[2],
      kind: params[3],
      state: params[4],
      cause: params[5]
    })
  ensure
    db&.close
  end
end

shutdown = Queue.new
Signal.trap('TERM') { shutdown.push(:term) }
Signal.trap('INT')  { shutdown.push(:term) }

Thread.new do
  shutdown.pop
  STATE.shutting_down = true
  begin
    write_sample!('transition', cause: 'sigterm')
  rescue Exception => e
    warn("sigterm sample failed: #{e.class}: #{e.message}")
  end
  exit!(0)
end

Thread.new do
  loop do
    sleep(SAMPLE_INTERVAL)
    write_sample!
  rescue => e
    Sentry.capture_exception(e)
  end
end

write_sample!('transition', cause: 'boot')

begin
  tickers = fetch_tickers
rescue => e
  write_sample!('transition', cause: 'tickers_failed',
                detail: { error: { class: e.class.name, message: e.message } })
  Sentry.capture_exception(e)
  raise
end

symbols = "A.#{tickers.join(',A.')}"

write_sample!('transition', cause: 'tickers_fetched', detail: { count: tickers.size })

loop do
  STATE.connection_id    = SecureRandom.uuid
  STATE.connected_at     = Time.now
  STATE.backoff          = false
  STATE.last_message_at  = nil
  STATE.first_message_at = nil
  STATE.last_error       = nil

  subscriber = Thread.new do
    redis      = Redis.new(REDIS_OPTS)
    last_epoch = {}

    begin
      client = Polygonio::Websocket::Client.new('stocks', API_KEY, delayed: true)

      client.subscribe(symbols) do |message|
        now = Time.now
        STATE.first_message_at = now if STATE.last_message_at.nil?
        STATE.last_message_at  = now

        STATE.frames += 1
        STATE.events += message.size

        redis.pipelined do |pipe|
          message.each do |data|
            # corrections arrive up to 15 min late; drop anything older than
            # what we've already written for this symbol
            next if last_epoch[data.sym] && data.e < last_epoch[data.sym]
            last_epoch[data.sym] = data.e

            lag_ms = ((now.to_f - (data.e / 1000.0)) * 1000).to_i
            STATE.max_lag_ms = lag_ms if lag_ms > STATE.max_lag_ms
            STATE.sum_lag_ms += lag_ms
            STATE.sampled_events += 1
            STATE.symbols << data.sym
            
            if data.c.to_f > 0
              pipe.setex("price:#{data.sym}", SIX_DAYS, data.c)
              pipe.publish("price_channel:#{data.sym}", data.c.to_json)
            end
            
            if data.op.to_f > 0
              pipe.setex("open:#{data.sym}", SIX_DAYS, data.op)
            end
            
          end
        end
      end
    rescue => e
      STATE.last_error = { class: e.class.name, message: e.message }
      Sentry.capture_exception(e)
    ensure
      begin
        redis.close
      rescue StandardError
        nil
      end
    end
  end

  STATE.subscriber = subscriber
  write_sample!('transition', cause: 'subscriber_spawned')

  loop do
    sleep(SAMPLE_INTERVAL)
    break unless subscriber.alive?
    break if derive_state == 'stale'
  end

  reason = if subscriber.alive?
             'stale'
           elsif STATE.last_error
             'error'
           else
             'closed'
           end

  subscriber.kill
  
  joined = begin
      subscriber.join(JOIN_TIMEOUT)
    rescue Exception => e
      STATE.last_error ||= { class: e.class.name, message: e.message }
      subscriber
    end
    
    
  STATE.backoff = true
  write_sample!('transition', cause: reason, detail: {
    join_timed_out: joined.nil?,
    error: STATE.last_error
  }.compact)

  # cleared only after the teardown sample, which still needs to carry the id so the
  # connection has a recorded end. Samples written during the backoff belong to no
  # connection, and leaving the old id set would keep crediting them to a dead one —
  # unbounded if a reconnect ever wedges.
  STATE.connection_id = nil

  sleep(BACKOFF)
end