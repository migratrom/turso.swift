# Stream sync HTTP responses into the native engine

## Summary

`SyncIODriver.handleHTTP(_:)` currently uses `URLSession.data(for:)`. This buffers an entire HTTP response in memory before passing it to the native sync engine with `turso_sync_database_io_push_buffer`.

Pull responses can contain a full database bootstrap or a large set of incremental pages. Buffering the complete response makes peak memory usage proportional to the response size and delays processing until the server has finished sending it.

## Current behavior

```swift
let (data, response) = try await URLSession.shared.data(for: request)

// ...validate the response...

if !data.isEmpty {
  try withSlice(data) { slice in
    try NativeStatus.check(turso_sync_database_io_push_buffer(item.pointer, &slice))
  }
}
```

Even when the server sends `/pull-updates` as a chunked or otherwise streaming response, `data(for:)` materializes it as one `Data` value.

## Desired behavior

Consume the response incrementally and forward bounded chunks to the native engine as they arrive. Possible implementations include:

- `URLSession.bytes(for:)` where supported.
- A `URLSessionDataDelegate` implementation for finer control over chunk delivery, cancellation, redirects, and backpressure.

The implementation must set the HTTP status on the native I/O item before forwarding response bytes and must preserve the existing poisoning and completion behavior when an error occurs.

## Acceptance criteria

- Response bytes are forwarded through `turso_sync_database_io_push_buffer` incrementally rather than accumulated into one response-sized `Data` value.
- Peak buffering is bounded independently of the total pull or bootstrap size.
- HTTP status codes are delivered to the native engine before response body chunks.
- Empty response bodies still complete successfully.
- Task cancellation cancels the underlying URL request and surfaces as `TursoError.cancelled` through the existing I/O path.
- Transport failures, invalid HTTP responses, and native buffer errors poison and complete the I/O item consistently with the current implementation.
- Authentication and existing request headers remain unchanged.
- Tests cover a multi-chunk response, an empty response, a non-2xx response with a body, cancellation, and a mid-stream transport failure.

## Implementation notes

- Avoid constructing a fresh `Data` value for every individual byte when using `AsyncBytes`; coalesce bytes into fixed-size chunks before calling the native API.
- Confirm whether `turso_sync_database_io_push_buffer` applies backpressure synchronously. If the native engine can only consume data after callbacks are stepped, coordinate chunk delivery with the engine rather than allowing unbounded queued chunks.
- Keep the response task alive until all chunks have been forwarded, then let the existing `turso_sync_database_io_done` flow mark the item complete.
- Verify the minimum Apple platform versions before choosing `URLSession.bytes(for:)`; use the delegate approach if the package's supported deployment targets require it.
