# ADR-0001: Use Tokio as the async runtime

## Status
Accepted

## Context
fastcache needs to handle thousands of concurrent client connections efficiently.
The two viable options for Rust async runtimes are Tokio and async-std. We need
an event-driven architecture that can handle the Redis protocol (RESP) over TCP
with minimal latency overhead.

## Decision
We will use Tokio as the sole async runtime for fastcache.

Reasons:
- Tokio has the largest ecosystem and best documentation for network services
- tokio::net::TcpListener and TcpStream are battle-tested at scale
- The tokio-util crate provides codec abstractions ideal for RESP framing
- DashMap (our chosen concurrent map) is designed for use with Tokio
- Most Rust networking libraries (hyper, tonic, axum) are built on Tokio,
  making future HTTP API additions straightforward

## Consequences
- All async code must use `#[tokio::main]` or `#[tokio::test]` -- mixing runtimes
  will cause panics at runtime
- We gain access to tokio::sync primitives (Notify, RwLock, broadcast) which are
  specifically designed for async contexts
- Contributors must understand Tokio's cooperative scheduling model -- long-running
  synchronous operations must use `tokio::task::spawn_blocking`
- We accept Tokio's compile-time cost (~15s added to clean builds)

## Alternatives Considered

### async-std
Simpler API surface but smaller ecosystem. The lack of a codec/framing abstraction
equivalent to tokio-util would require us to write our own RESP parser from scratch.
The community momentum has clearly shifted to Tokio.

### No async (thread-per-connection)
Simpler mental model but does not scale past ~10K concurrent connections on typical
hardware. Redis itself uses a single-threaded event loop; we want to do better with
a multi-threaded async approach.
