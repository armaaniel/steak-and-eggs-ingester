require "redis"
require "oj"
require "polygonio"
require "pg"
require "sentry-ruby"
require "tzinfo"
require "uri"
require "json"
require "time"
require "securerandom"

Sentry.init { |config| config.dsn = ENV["SENTRY_DSN"] }

REDIS_URL    = ENV.fetch("REDIS_URL")
DATABASE_URL = ENV.fetch("DATABASE_URL")
API_KEY      = ENV.fetch("API_KEY")

SIX_DAYS        = 518400
SAMPLE_INTERVAL = 60
STALE_AFTER     = 120
BACKOFF         = 60
JOIN_TIMEOUT    = 10
FEED_DELAY      = 900

TZ = TZInfo::Timezone.get("America/New_York")

DB = URI.parse(DATABASE_URL)

BASE_PG_OPTS = {
  host:     DB.host,
  port:     DB.port,
  dbname:   DB.path.delete_prefix("/"),
  user:     DB.user,
  password: DB.password,

  connect_timeout:     2,
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
  :connected_at, :last_message_at, :first_message_at, :last_error, :force_disconnect,
  :frames, :events, :sum_lag_ms, :sampled_events, :symbols,
  keyword_init: true
)

STATE = State.new(
  boot_id: SecureRandom.uuid,
  shutting_down: false,
  backoff: false,
  frames: 0,
  events: 0,
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

def receiving_session_data?
  now = TZ.to_local(Time.now - FEED_DELAY)
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
  return 'idle'       unless receiving_session_data?
  return 'stale'      if since > STALE_AFTER

  return 'streaming'
end

def write_sample!(kind = 'tick', cause: nil, detail: nil)
  row = seen = nil

  SAMPLE_LOCK.synchronize do
    seen = STATE.symbols
    row = {
      at:               Time.now.utc.iso8601(6),
      boot_id:          STATE.boot_id,
      connection_id:    STATE.connection_id,
      kind:             kind,
      state:            derive_state,
      cause:            cause,
      frames:           STATE.frames,
      events:           STATE.events,
      symbols:          seen.size,
      sum_lag_ms:       STATE.sum_lag_ms,
      sampled_events:   STATE.sampled_events,
      last_message_at:  STATE.last_message_at&.iso8601(6),
      first_message_at: STATE.first_message_at&.iso8601(6),
      detail:           detail && JSON.generate(detail)
    }

    STATE.symbols        = Set.new
    STATE.sum_lag_ms     = 0
    STATE.sampled_events = 0
  end

  summary = row.slice(:at, :kind, :state, :cause, :boot_id, :connection_id)
  puts JSON.generate(summary)

  columns      = row.keys.join(', ')
  placeholders = (1..row.size).map { |i| "$#{i}" }.join(', ')
  sql = "INSERT INTO ingester_samples (#{columns}) VALUES (#{placeholders})"

  db = nil
  begin
    db = PG.connect(PG_OPTS)
    db.exec_params(sql, row.values)
  rescue => e
    SAMPLE_LOCK.synchronize do
      STATE.sum_lag_ms     += row[:sum_lag_ms]
      STATE.sampled_events += row[:sampled_events]
      STATE.symbols.merge(seen)
    end
    Sentry.capture_exception(e, extra: summary)
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
  STATE.force_disconnect = false

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
            
            next if last_epoch[data.sym] && data.e < last_epoch[data.sym] 
            last_epoch[data.sym] = data.e

            lag_ms = ((now.to_f * 1000) - data.e).to_i
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
      if e.is_a?(Dry::Struct::Error) && e.message.include?('force_disconnect')
        STATE.force_disconnect = true
      else
        STATE.last_error = { class: e.class.name, message: e.message }
        Sentry.capture_exception(e)
      end
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
           elsif STATE.force_disconnect
             'force_disconnect'
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

  STATE.connection_id = nil
  STATE.frames = 0
  STATE.events = 0

  sleep(BACKOFF)
end