# Ethereum JSON-RPC Server

HTTP JSON-RPC 2.0 server implementation for the Ethereum client, based on Erigon's RPC architecture.

## Features

- **Full JSON-RPC 2.0 Compliance**: Supports all required JSON-RPC 2.0 features
- **HTTP Server**: Configurable port with graceful shutdown
- **Batch Requests**: Handle multiple requests in a single HTTP call
- **Comprehensive Error Handling**: Standard JSON-RPC 2.0 error codes
- **Ethereum API**: Complete `eth_*`, `net_*`, `web3_*`, and `debug_*` namespace support

## Architecture

```
src/rpc/
├── server.zig    - HTTP server with JSON-RPC 2.0 protocol handling
└── eth_api.zig   - Ethereum RPC method implementations
```

## Usage

### Starting the Server

```zig
const std = @import("std");
const Server = @import("rpc/server.zig").Server;
const kv = @import("kv/kv.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize database
    var db = kv.Database.init(allocator);
    defer db.deinit();

    // Create server
    var server = Server.init(allocator, db, 1, 8545); // chain_id=1, port=8545

    // Start server (runs in background thread)
    try server.start();
    defer server.stop();

    std.log.info("RPC server running on http://0.0.0.0:8545", .{});

    // Keep main thread alive
    std.time.sleep(std.time.ns_per_hour);
}
```

## JSON-RPC 2.0 Format

### Single Request

```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "eth_blockNumber",
    "params": []
  }'
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": "0x1234"
}
```

### Batch Request

```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '[
    {"jsonrpc": "2.0", "id": 1, "method": "eth_blockNumber", "params": []},
    {"jsonrpc": "2.0", "id": 2, "method": "eth_chainId", "params": []}
  ]'
```

**Response:**
```json
[
  {"jsonrpc": "2.0", "id": 1, "result": "0x1234"},
  {"jsonrpc": "2.0", "id": 2, "result": "0x1"}
]
```

### Error Response

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "error": {
    "code": -32601,
    "message": "Method not found"
  }
}
```

## Supported Methods

### `eth_*` Namespace

- `eth_blockNumber` - Get latest block number
- `eth_chainId` - Get chain ID
- `eth_syncing` - Get sync status
- `eth_gasPrice` - Get current gas price
- `eth_maxPriorityFeePerGas` - Get max priority fee (EIP-1559)
- `eth_getBlockByNumber` - Get block by number
- `eth_getBlockByHash` - Get block by hash
- `eth_getTransactionByHash` - Get transaction by hash
- `eth_getTransactionReceipt` - Get transaction receipt
- `eth_getBalance` - Get account balance
- `eth_getCode` - Get contract code
- `eth_getStorageAt` - Get contract storage value
- `eth_getTransactionCount` - Get account nonce
- `eth_call` - Execute call (read-only)
- `eth_estimateGas` - Estimate gas for transaction
- `eth_sendRawTransaction` - Submit signed transaction
- `eth_feeHistory` - Get fee history (EIP-1559)
- `eth_newFilter` - Create log filter
- `eth_newBlockFilter` - Create block filter
- `eth_getFilterChanges` - Get filter changes

### `net_*` Namespace

- `net_version` - Get network ID
- `net_listening` - Check if node is listening
- `net_peerCount` - Get peer count

### `web3_*` Namespace

- `web3_clientVersion` - Get client version
- `web3_sha3` - Calculate Keccak-256 hash

### `debug_*` Namespace

- `debug_traceTransaction` - Trace transaction execution
- `debug_traceBlockByNumber` - Trace block execution

## Error Codes

Standard JSON-RPC 2.0 error codes:

| Code | Message | Description |
|------|---------|-------------|
| -32700 | Parse error | Invalid JSON |
| -32600 | Invalid Request | Invalid JSON-RPC request |
| -32601 | Method not found | Method does not exist |
| -32602 | Invalid params | Invalid method parameters |
| -32603 | Internal error | Internal server error |

## Server Lifecycle

### Starting

```zig
try server.start();
```

- Creates TCP listener on configured port
- Spawns background thread for event loop
- Returns immediately, server runs in background

### Stopping

```zig
server.stop();
```

- Sets shutdown flag
- Waits for server thread to finish
- Closes TCP listener
- Graceful shutdown of all connections

## Implementation Details

### HTTP Handling

- Accepts POST requests to `/` endpoint
- Parses HTTP headers to extract JSON body
- Supports batch requests (JSON array)
- Returns proper HTTP headers and status codes

### Request Routing

1. Parse JSON-RPC request
2. Validate `jsonrpc: "2.0"` field
3. Route by method prefix (`eth_`, `net_`, `web3_`, `debug_`)
4. Parse parameters and call handler
5. Format response as JSON-RPC 2.0

### Parameter Parsing

Type-safe parameter parsing with validation:

- **Addresses**: 20-byte hex strings (`0x...`)
- **Hashes**: 32-byte hex strings (`0x...`)
- **Block Numbers**: Hex integers or tags (`latest`, `earliest`, etc.)
- **Quantities**: Hex integers (`0x...`)
- **Data**: Variable-length hex strings (`0x...`)

### Notifications

Requests with `id: null` are treated as notifications and do not return responses.

## Testing

```bash
zig build test-unit -Dtest-filter='server'
```

Tests cover:
- Server initialization
- Parameter parsing (addresses, hashes, quantities)
- JSON-RPC request handling
- Error responses

## Reference

- [JSON-RPC 2.0 Specification](https://www.jsonrpc.org/specification)
- [Ethereum JSON-RPC API](https://ethereum.org/en/developers/docs/apis/json-rpc/)
- [Erigon RPC Implementation](https://github.com/ledgerwatch/erigon)
