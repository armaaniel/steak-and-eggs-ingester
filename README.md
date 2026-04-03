# Steak & Eggs — Price Ingester

Standalone price ingestion service for [steakneggs.app](https://steakneggs.app/) — a trading simulator with streaming market data.

Maintains a persistent WebSocket connection to Polygon.io, caching prices in Redis and broadcasting to clients via Redis pub/sub. Decoupled from the rails backend for independent scaling and deploys.

Backend repo: [steak-and-eggs](https://github.com/armaaniel/steak-and-eggs)

Frontend repo: [steak-and-eggs-spa](https://github.com/armaaniel/steak-and-eggs-spa)

Mobile app: [steak-and-eggs-mobile](https://github.com/armaaniel/steak-and-eggs-mobile)
