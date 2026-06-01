# Deep Code Review: EPG Feed Downloads

Date: 2026-05-28
Scope: End-to-end operational behavior and debug logging for EPG feed downloads (XMLTV + Schedules Direct), including scheduling, transfer execution, error handling, retries, and transfer-state persistence.

## Findings (ordered by severity)

1. High: Conflicting timeout sources can make Schedules Direct timeout behavior inconsistent and misleading in logs.
   - Evidence:
     - [src/IptvHub.Service/Services/SourceIngestionService.cs](src/IptvHub.Service/Services/SourceIngestionService.cs#L25)
     - [src/IptvHub.Service/Services/SourceIngestionService.cs](src/IptvHub.Service/Services/SourceIngestionService.cs#L34)
     - [src/IptvHub.Service/Services/SourceIngestionService.cs](src/IptvHub.Service/Services/SourceIngestionService.cs#L1227)
     - [src/IptvHub.Service/Services/SourceIngestionService.cs](src/IptvHub.Service/Services/SourceIngestionService.cs#L1232)
     - [src/IptvHub.Service/Services/SourceIngestionService.cs](src/IptvHub.Service/Services/SourceIngestionService.cs#L1237)
   - Why this matters: HttpClient default timeout and custom linked-CTS timeout can diverge; operators may see a 120s timeout message even when a different timeout fired first.
   - Recommendation: Use one authoritative timeout mechanism (commonly HttpClient.Timeout = InfiniteTimeSpan plus per-request linked CTS timeout) and log actual elapsed duration.

2. High: Test feed endpoint can hide failures from operational telemetry by returning HTTP 200 with error payload and no strong server log context.
   - Evidence:
     - [src/IptvHub.Service/Api/Controllers/EpgController.cs](src/IptvHub.Service/Api/Controllers/EpgController.cs#L279)
     - [src/IptvHub.Service/Api/Controllers/EpgController.cs](src/IptvHub.Service/Api/Controllers/EpgController.cs#L335)
   - Why this matters: Alerting and health probes cannot reliably distinguish success from failure on this endpoint.
   - Recommendation: Emit structured error logs for test failures and return non-2xx for failing tests.

3. High: XMLTV download path has no payload-size guard before in-memory decode and parse.
   - Evidence:
     - [src/IptvHub.Service/Services/SourceIngestionService.cs](src/IptvHub.Service/Services/SourceIngestionService.cs#L968)
     - [src/IptvHub.Service/Services/SourceIngestionService.cs](src/IptvHub.Service/Services/SourceIngestionService.cs#L977)
     - [src/IptvHub.Service/Parsers/XmlTvParser.cs](src/IptvHub.Service/Parsers/XmlTvParser.cs#L22)
   - Why this matters: Large or malformed feeds can cause high memory pressure and GC stalls/OOM.
   - Recommendation: Add explicit max-content limits and prefer streaming parse path for large feeds.

4. Medium: Low-level Schedules Direct request layer lacks structured request/response telemetry.
   - Evidence:
     - [src/IptvHub.Service/Services/SourceIngestionService.cs](src/IptvHub.Service/Services/SourceIngestionService.cs#L1213)
     - [src/IptvHub.Service/Services/SourceIngestionService.cs](src/IptvHub.Service/Services/SourceIngestionService.cs#L1243)
     - [src/IptvHub.Service/Services/SourceIngestionService.cs](src/IptvHub.Service/Services/SourceIngestionService.cs#L1260)
   - Why this matters: Hard to isolate token vs lineup vs schedules vs programs failures during incidents.
   - Recommendation: Add structured logs for method, relativePath, status code, elapsedMs, payload bytes, and request category.

5. Medium: XMLTV retry logging omits exception details and endpoint context at retry time.
   - Evidence:
     - [src/IptvHub.Service/Services/SourceIngestionService.cs](src/IptvHub.Service/Services/SourceIngestionService.cs#L990)
   - Why this matters: Intermittent transport issues become slower to diagnose.
   - Recommendation: Include exception type/message and redacted URL host/path in retry warnings.

6. Medium: Feed transfer state updates are read-modify-write of whole server records and can race under concurrent refresh/manual download.
   - Evidence:
     - [src/IptvHub.Service/Services/ProviderService.cs](src/IptvHub.Service/Services/ProviderService.cs#L397)
     - [src/IptvHub.Service/Api/Controllers/EpgController.cs](src/IptvHub.Service/Api/Controllers/EpgController.cs#L996)
   - Why this matters: CurrentStatus/LastTransfer fields can be stale or oscillate under overlap.
   - Recommendation: Use atomic patch semantics or optimistic concurrency/version checks for EpgFeeds mutations.

7. Medium: XMLTV retry policy is narrow and only captures selected premature-end signatures.
   - Evidence:
     - [src/IptvHub.Service/Services/SourceIngestionService.cs](src/IptvHub.Service/Services/SourceIngestionService.cs#L982)
     - [src/IptvHub.Service/Services/SourceIngestionService.cs](src/IptvHub.Service/Services/SourceIngestionService.cs#L988)
   - Why this matters: Other transient network failures still fail hard on first attempt.
   - Recommendation: Apply unified transient retry policy with categorized exceptions, bounded attempts, and jitter.

## Operational observations

- Good: Feed-level status model exists (`LastTransferUtc`, `LastTransferStatus`, `CurrentStatus`, `LastTransferMessage`) and is persisted.
  - [src/IptvHub.Service/Models/EpgFeed.cs](src/IptvHub.Service/Models/EpgFeed.cs)

- Good: Manual download endpoint captures duration and bytes transferred for XMLTV.
  - [src/IptvHub.Service/Api/Controllers/EpgController.cs](src/IptvHub.Service/Api/Controllers/EpgController.cs#L434)

- Good: Schedules Direct request timeout now throws explicit TimeoutException with endpoint details.
  - [src/IptvHub.Service/Services/SourceIngestionService.cs](src/IptvHub.Service/Services/SourceIngestionService.cs#L1237)

- Gap: Provider refresh path currently logs feed-level fetch and merge counts, but no per-request Schedules Direct telemetry.
  - [src/IptvHub.Service/Services/ProviderService.cs](src/IptvHub.Service/Services/ProviderService.cs#L283)

## Suggested next implementation batch

1. Timeout unification and elapsed timing logs for all Schedules Direct HTTP calls.
2. Structured retry logs (endpoint + exception category + attempt count) for XMLTV and Schedules Direct.
3. XMLTV size guard and optional streaming parse fallback.
4. Concurrency-safe transfer-state persistence for feed status updates.

## Testing gaps to close

1. Integration tests for Schedules Direct timeout behavior (60s/120s boundaries and message correctness).
2. Load test with large XMLTV feed to validate memory and failure-mode logging.
3. Concurrency test for scheduled refresh + manual EPG download overlapping same feed state.
