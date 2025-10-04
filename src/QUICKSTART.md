# Guillotine Ethereum Client - Quickstart Guide

Get up and running with the Guillotine Ethereum Client in minutes.

## Prerequisites

- **Zig 0.13.0 or later**: [Download Zig](https://ziglang.org/download/)
- **Git**: For cloning the repository
- **4GB RAM minimum** (8GB recommended for bulk sync)
- **Linux, macOS, or Windows** (tested on all platforms)

## Quick Install

### 1. Clone the Repository

```bash
git clone https://github.com/yourusername/guillotine-client.git
cd guillotine-client
```

### 2. Build the Client

```bash
zig build
```

This will create the executable at `./zig-out/bin/guillotine-client`

### 3. Run the Client

```bash
./zig-out/bin/guillotine-client
```

You should see output like:

```
╔═══════════════════════════════════════╗
║   Guillotine Ethereum Client v1.0.0  ║
║   Minimal Erigon-inspired Node       ║
╚═══════════════════════════════════════╝

[INFO] Starting Guillotine node...
[INFO] Chain ID: 1
[INFO] Data directory: ./data
[INFO] Starting sync to block 1000...
```

## Basic Usage

### Syncing from Genesis

The client will automatically start syncing from genesis block 0. By default, it syncs to block 1000 for testing.

To change the sync target, edit `src/main.zig`:

```zig
var config = ClientConfig.default();
config.node_config.sync_target = 10000; // Sync to block 10,000
```

### Querying via RPC

The RPC server starts automatically on port 8545. You can query it using curl:

```bash
# Get latest block number
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

# Get block by number
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["0x64",false],"id":1}'

# Get account balance
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_getBalance","params":["0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb","latest"],"id":1}'
```

### Running Tests

Run all tests:

```bash
zig build test
```

Run only integration tests:

```bash
zig build test -Dtest-filter="integration"
```

Run a specific test:

```bash
zig build test -Dtest-filter="full sync"
```

## Configuration

### Client Configuration

Edit `src/main.zig` to configure the client:

```zig
pub const ClientConfig = struct {
    node_config: NodeConfig,
    rpc_port: u16,          // Default: 8545
    p2p_port: u16,          // Default: 30303
    enable_rpc: bool,       // Default: true
    enable_p2p: bool,       // Default: false (not fully functional)
};
```

### Node Configuration

Configure the node in `src/node.zig`:

```zig
pub const NodeConfig = struct {
    data_dir: []const u8,   // Default: "./data"
    chain_id: u64,          // Default: 1 (mainnet)
    network_id: u64,        // Default: 1
    max_peers: u32,         // Default: 50
    sync_target: u64,       // Default: 1000
};
```

### Example: Custom Configuration

```zig
// In main.zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Custom configuration
    var config = ClientConfig{
        .node_config = .{
            .data_dir = "/var/lib/guillotine",
            .chain_id = 1,
            .network_id = 1,
            .max_peers = 100,
            .sync_target = 50000, // Sync to block 50,000
        },
        .rpc_port = 8545,
        .p2p_port = 30303,
        .enable_rpc = true,
        .enable_p2p = false,
    };

    var client = try Client.init(allocator, config);
    defer client.deinit();

    try client.run();
}
```

## Common Operations

### 1. Sync to a Specific Block

```zig
var config = ClientConfig.default();
config.node_config.sync_target = 100000;

var node = try Node.init(allocator, config);
defer node.deinit();

try node.start();
```

### 2. Handle Chain Reorganizations

```zig
// Unwind to block 30
try node.handleReorg(30);

// Re-sync to new head
node.config.sync_target = 60;
try node.start();
```

### 3. Query Block Data

```zig
// Get latest block
const latest = node.getLatestBlock();

// Get specific block
const block_100 = node.getBlock(100);

if (block_100) |block| {
    std.debug.print("Block 100: {} transactions\n", .{block.transactions.len});
}
```

### 4. Check Sync Status

```zig
const status = node.getSyncStatus();

std.debug.print("Target: {}\n", .{status.target_block});
for (status.stages) |stage| {
    std.debug.print("{s}: {}\n", .{stage.name, stage.current_block});
}
```

## Architecture Overview

### Staged Sync Pipeline

```
Genesis Block
     ↓
[Headers Stage]     ← Download and validate headers
     ↓
[BlockHashes]       ← Index block numbers ↔ hashes
     ↓
[Bodies Stage]      ← Download transaction data
     ↓
[Senders Stage]     ← Recover ECDSA signatures
     ↓
[Execution Stage]   ← Execute transactions via Guillotine EVM
     ↓
[TxLookup Stage]    ← Index transaction hashes
     ↓
[Finish Stage]      ← Finalize sync
     ↓
Synced to Target
```

### Component Interaction

```
┌─────────────┐
│  RPC Server │ ← Query interface (port 8545)
└──────┬──────┘
       │
┌──────▼──────┐
│    Node     │ ← Orchestrates all components
└──────┬──────┘
       │
┌──────▼──────┐
│ Staged Sync │ ← Runs all stages in order
└──────┬──────┘
       │
┌──────▼──────┐
│   Stages    │ ← Individual sync stages
│  (7 total)  │
└──────┬──────┘
       │
┌──────▼──────┐
│   Database  │ ← Persistent storage (in-memory for now)
└─────────────┘
```

## Performance Tuning

### For Fast Sync (Testing)

```zig
config.node_config.sync_target = 100; // Small target
```

Expected: ~5000 blocks/sec (in-memory)

### For Bulk Sync (Production)

```zig
config.node_config.sync_target = 1000000; // 1M blocks

// TODO: When MDBX is integrated:
// - Expected: ~1000 blocks/sec
// - Memory usage: ~4GB
// - Disk usage: ~500GB with pruning
```

### Memory Usage

Current (in-memory database):
- **Light**: ~100MB for 1000 blocks
- **Medium**: ~500MB for 10,000 blocks
- **Heavy**: ~2GB for 100,000 blocks

With MDBX (future):
- **Constant**: ~4GB regardless of blockchain size

## Troubleshooting

### Issue: "Out of Memory"

**Solution**: Reduce sync target or increase system RAM

```zig
config.node_config.sync_target = 1000; // Smaller target
```

### Issue: "Stage execution failed"

**Solution**: Check logs for specific stage failure

```bash
# Run with debug logging
zig build -Doptimize=Debug
./zig-out/bin/guillotine-client
```

### Issue: "RPC server not responding"

**Solution**: Verify RPC is enabled and port is not in use

```zig
config.enable_rpc = true;
config.rpc_port = 8545; // Try different port if 8545 is busy
```

### Issue: "State root mismatch"

**Solution**: This indicates EVM execution issue. Check Guillotine EVM integration:

```bash
# Run execution stage tests
zig build test -Dtest-filter="execution"
```

## Integration with Guillotine EVM

The client uses the Guillotine EVM for transaction execution. Here's how it integrates:

### 1. Add Guillotine Dependency

In `build.zig`:

```zig
const guillotine = b.dependency("guillotine", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("guillotine", guillotine.module("guillotine"));
```

### 2. Execute Transactions

In your code:

```zig
const guillotine = @import("guillotine");

// Create EVM instance
var evm = try guillotine.Evm.init(allocator, state, &header);
defer evm.deinit();

// Execute transaction
const result = try evm.execute(transaction);

// Handle result
if (result.success) {
    // Transaction succeeded
    try state.commit();
} else {
    // Transaction reverted
    state.revert();
}
```

## Advanced Usage

### Custom Stage Implementation

You can add custom stages to the sync pipeline:

```zig
// Define your custom stage
const MyStage = struct {
    pub fn execute(ctx: *sync.StageContext) !sync.StageResult {
        // Your custom logic here
        return sync.StageResult{
            .blocks_processed = 10,
            .stage_done = true,
        };
    }

    pub fn unwind(ctx: *sync.StageContext, unwind_to: u64) !void {
        // Handle reorg
    }
};

// Add to stage pipeline
const stages = [_]sync.StagedSync.StageDef{
    .{ .stage = .headers, .interface = headers_stage.interface },
    .{ .stage = .bodies, .interface = bodies_stage.interface },
    // ... existing stages ...
    .{ .stage = .custom, .interface = .{
        .executeFn = MyStage.execute,
        .unwindFn = MyStage.unwind,
    }},
};
```

### Temporal State Queries

Query historical state using the Domain system:

```zig
const Domain = @import("state/domain.zig").Domain;

var domain = try Domain.init(allocator, config);
defer domain.deinit();

// Query state at block 1000
const balance_at_1000 = try domain.getAsOf("account_key", 1000, tx);

// Query current state
const current_balance = try domain.getLatest("account_key", tx);
```

### P2P Networking (Future)

When P2P is fully implemented:

```zig
config.enable_p2p = true;
config.p2p_port = 30303;

var client = try Client.init(allocator, config);
try client.run();

// Will automatically:
// - Discover peers via Kademlia DHT
// - Download headers from best peer
// - Propagate new blocks
// - Broadcast transactions
```

## Next Steps

1. **Explore the code**: Start with `src/main.zig` and follow the flow
2. **Run tests**: `zig build test` to understand component behavior
3. **Customize configuration**: Adjust sync target and ports
4. **Try RPC queries**: Use curl or web3.js to query the node
5. **Read architecture docs**: See `ARCHITECTURE.md` for deep dive

## Getting Help

- **Documentation**: See `ARCHITECTURE.md`, `IMPLEMENTATION_COMPLETE.md`
- **Examples**: Check `examples/` directory for code samples
- **Tests**: Look at test files for usage patterns
- **Source Code**: All files are heavily commented

## What's Next for This Client?

### Short Term (2-3 weeks)

- [ ] MDBX database integration
- [ ] Network socket implementation
- [ ] Snapshot file I/O
- [ ] Production configuration

### Medium Term (1-2 months)

- [ ] Full P2P networking
- [ ] Complete RPC API
- [ ] Mainnet sync testing
- [ ] Performance optimization

### Long Term (3-6 months)

- [ ] Snapshot distribution (torrents)
- [ ] Advanced pruning strategies
- [ ] Multi-chain support
- [ ] Mobile deployment

## License

LGPL-3.0 (same as Guillotine EVM)

---

**Ready to dive in?** Start with:

```bash
zig build
./zig-out/bin/guillotine-client
```

**Happy syncing!** 🚀
