require "redis"
require "polygonio"
require "pg"
require "sentry-ruby"
require "tzinfo"

Sentry.init { |config| config.dsn = ENV["SENTRY_DSN"] }

REDIS_URL = ENV.fetch("REDIS_URL")
DATABASE_URL = ENV.fetch("DATABASE_URL")
API_KEY = ENV.fetch("API_KEY")
SIX_DAYS = 6 * 24 * 60 * 60

HOLIDAYS = [
  "2026-01-01", "2026-01-19", "2026-02-16", "2026-04-03", "2026-05-25","2026-06-19", "2026-07-03", 
  "2026-09-07", "2026-11-26", "2026-12-25"].map { |n| Date.parse(n) }
  
tz = TZInfo::Timezone.get("America/New_York")  

def market_open?(tz)
  now = tz.now
  return false if now.saturday? || now.sunday?
  return false if HOLIDAYS.include?(now.to_date)
  (now.hour == 9 && now.min >= 30) || (now.hour >= 10 && now.hour < 16)
end

def fetch_tickers
  db = PG.connect(DATABASE_URL)
  symbols = db.exec("SELECT symbol FROM tickers").map { |n| n["symbol"] }
  db.close
  symbols
end

redis = Redis.new(url: REDIS_URL)
tickers = fetch_tickers
symbols = "A.#{tickers.join(',A.')}"

loop do
  last_message_at = tz.now
  puts "starting connection at #{last_message_at}"

  subscriber = Thread.new do
    client = Polygonio::Websocket::Client.new("stocks", API_KEY, delayed: true)

    client.subscribe(symbols) do |message|
      last_message_at = Time.now
      message.each do |data|
        redis.setex("price:#{data.sym}", SIX_DAYS, data.c)
        redis.setex("open:#{data.sym}", SIX_DAYS, data.op)
        redis.publish("price_channel:#{data.sym}", data.c.to_json)
      end
    end
  rescue => e
    if e.message.include?("max_connections")
      puts "Max connections at #{Time.now}: #{e.message}"
    else
      puts "Force disconnected at #{Time.now}: #{e.class}: #{e.message}"
    end
    Sentry.capture_exception(e)
  end

  loop do
    sleep(60)
    break unless subscriber.alive?
    break if market_open?(tz) && Time.now - last_message_at > 300
  end

  subscriber.kill
  sleep(60)
  puts "restarting at #{Time.now}: last at #{last_message_at}"
end