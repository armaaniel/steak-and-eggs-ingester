# Steak & Eggs — Price Ingester

Streams live prices into [steakneggs.app](https://steakneggs.app/), a paper-trading app. It's one Ruby process that does three things:
- holds Polygon.io's WebSocket
- writes every price to Valkey and publishes it for Rails to push to clients
- reports its own health to Postgres, for [DataCat](https://steakneggs.app/datacat)

Backend repo, with the architecture diagram: [steak-and-eggs](https://github.com/armaaniel/steak-and-eggs)

Frontend repo: [steak-and-eggs-spa](https://github.com/armaaniel/steak-and-eggs-spa)

Mobile app: [steak-and-eggs-mobile](https://github.com/armaaniel/steak-and-eggs-mobile)

## How It Works

1. **Boot.** Read the ticker list from Postgres. Subscribe to Polygon's per-second bars (`A.<symbol>`) for every ticker, on the 15-minute-delayed feed.
2. **Each frame.** Polygon sends frames of one or more bars. Each frame gets one Redis pipeline, so it costs one round trip to Valkey however many bars it holds. For every bar, the pipeline sets `price:<symbol>` and `open:<symbol>` with a 6-day TTL and publishes the price to `price_channel:<symbol>`. It skips bars older than the last one seen for that symbol, and zero prices.
3. **Supervise.** The connection runs in its own thread, and the main loop checks it once a minute. If the thread has died or the connection has gone stale, the loop stops it, records why, waits 60 seconds and opens a new connection.

The ingester never talks to Rails or to clients. Valkey is the only interface: Rails' ActionCable streams `price_channel:<symbol>` to whoever is subscribed, and the REST API reads `price:<symbol>`.

## Why a Separate Process

- **Polygon allows one socket per key.** If the socket lived in Rails and Rails ran more than one task, each task would open its own, and they'd keep disconnecting each other. One small process holds the only socket.
- **A web server isn't built for a connection that stays open all day.** Rails' threads are there to serve requests that finish.
- **Each side deploys on its own.** Deploying Rails doesn't drop the feed, and a feed problem can't take down the API. Either one can restart while the other keeps going.

## Market Calendar

The ingester knows when the feed should be quiet, so a closed market doesn't look like a broken connection.

- The session runs from 4 AM to 8 PM Eastern on weekdays, covering pre-market and after-hours. On early-close days, it ends at 5 PM.
- Holidays and early closes are listed through 2028.
- The check uses feed time, which is now minus 15 minutes, so it agrees with the bars actually arriving.
- During the session, more than 55 seconds without a message is **stale** and triggers a reconnect. Outside it, silence is **idle**.

## Telemetry

The ingester never serves a request, so request traces can't see it. It reports on itself instead, by writing rows to the backend's `ingester_samples` table:
- a **tick** row every 60 seconds
- a **transition** row whenever something happens

Each row records its state, which is one of these:

| State | Meaning |
|---|---|
| `booting` | The process started, and no connection exists yet |
| `connecting` | A connection is open, but no message has arrived yet |
| `streaming` | Messages are arriving during the session |
| `idle` | The market is closed, so silence is expected |
| `stale` | The session is open, but nothing has arrived for 55 seconds |
| `dead` | The connection thread exited |
| `backoff` | Waiting 60 seconds before reconnecting |
| `shutdown` | ECS sent SIGTERM |

A transition row has a cause: `boot`, `tickers_fetched`, `tickers_failed`, `subscriber_spawned`, `stale`, `force_disconnect`, `error`, `closed` or `sigterm`. Errors go into a JSON `detail` column, with the class and message.

Every row carries:
- **IDs:** a `boot_id` per process and a `connection_id` per Polygon connection, so DataCat can show boots and connections as separate timelines.
- **Throughput:** running counts of frames and events for the current connection, plus how many distinct symbols traded since the last row.
- **Lag:** how long after each bar's end it arrived. The baseline is 902 seconds (15 minutes plus Polygon's 2-second holdback), and DataCat charts the lag above that baseline.
- **Time split:** how long the ingester spent handling frames versus waiting for the next one.

**How writes stay safe:**
- Each write opens a fresh Postgres connection, so there's no idle connection to keep alive between rows. Connecting times out after 2 seconds, and statements after 10.
- If a write fails, the lag totals and symbols carry into the next row instead of being lost, and the error goes to Sentry.
- On SIGTERM, the ingester writes a final `sigterm` row before exiting, so a deploy looks different from a crash.

## What the Telemetry Shows

- **Volume.** During regular hours, a typical minute brings 330–410 bars a second. The busiest minute is the last one before the 4 PM close, at up to about 2,450 bars a second, with around 8,000 symbols trading.
- **Lag.** In a typical minute of regular trading, bars arrive about half a second after the 902-second baseline. A day's worst minute reaches 2–4 seconds.
- **Headroom.** On a quarter of a vCPU, CPU sits around 11–18% for most of the day. The close is the tight spot: in the minutes before 4 PM, it peaks at 55–88%. That's where a bigger feed would run out first.
- **Polygon disconnects every night.** Just after midnight Eastern, Polygon sends a `force_disconnect`. The ingester records it, waits out the backoff and reconnects. Twice in 30 days, the socket went silent without the message. Silence at night is expected, so the ingester couldn't tell until the session opened at 4 AM, when it marked the connection stale and reconnected within 2 minutes.
- **Deploys.** The two deploys in the last 30 days left 63 and 80 seconds without prices. The new process had its first message a second after it booted, so nearly all of that gap is ECS stopping the old task and starting the new one.

## Deploys

Polygon allows one WebSocket per API key. ECS runs the service with `minimum_healthy_percent = 0` and `maximum_percent = 100`, so the old task stops before the new one starts. The new task then has to start on Fargate, boot and reconnect, which has taken 63–80 seconds. Bars that arrive in that gap are lost, not replayed, and Valkey keeps serving the last prices until new ones arrive.

GitHub Actions runs `ruby -c` on every PR. On a push to `main`, it builds an ARM64 image, pushes it to ECR and forces a new ECS deployment.

## Running Locally

```sh
bundle install
bundle exec ruby ingester.rb
```

It needs these environment variables:
- `API_KEY`: the Polygon key.
- `REDIS_URL`: TLS is always on, so this has to be a server that accepts TLS, like ElastiCache.
- `DATABASE_URL`: a database with the backend's `tickers` and `ingester_samples` tables.
- `SENTRY_DSN`: optional.

Because Polygon allows one socket per key, running it with the production key disconnects the production ingester.

## Trade-offs

- **New tickers wait for a restart.** The ticker list is read once at boot, so the nightly ticker sync only takes effect after the next deploy or restart.
- **Recovery is slow because it's simple.** The connection is checked on the same 60-second interval as the telemetry, and every reconnect waits a flat 60 seconds. A silent failure can mean up to about 3 minutes without prices. Checking every few seconds, and starting the backoff short, would recover in under a minute.
- **No redundancy.** It's one process and one connection, because that's all Polygon allows.
- **The market calendar needs a yearly update.** It's hardcoded through 2028. If a holiday is missing, the ingester waits for prices that never come, marks itself stale and reconnects about every 2 minutes all day.

## Tech Stack

Ruby 3.4 · polygonio (forked) · redis · pg · tzinfo · Oj · Sentry · Docker · ECS Fargate (ARM64) · GitHub Actions
