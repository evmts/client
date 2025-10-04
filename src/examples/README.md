# Guillotine Ethereum Client - Examples

This directory contains practical examples demonstrating how to use the Guillotine Ethereum Client.

## Examples

### 1. Basic Sync Node (`sync_node.zig`)

Shows how to create a simple node that syncs from genesis.

```bash
zig build-exe examples/sync_node.zig
./sync_node
```

**What it demonstrates**:
- Node configuration
- Initializing the client
- Starting sync
- Querying blocks

**Output**:
```
=== Guillotine Ethereum Sync Node Example ===
Configuration:
  Chain ID: 1
  Data directory: ./example_data
  Sync target: 1000 blocks
...
=== Sync Complete ===
Latest block: 1000
Block 100:
  Number: 100
  Transactions: 42
```

---

### 2. RPC Query Client (`rpc_query.zig`)

Demonstrates RPC server usage and query patterns.

```bash
zig build-exe examples/rpc_query.zig
./rpc_query
```

**What it demonstrates**:
- RPC server initialization
- Common RPC methods
- Equivalent curl commands

**Covered RPC methods**:
- `eth_blockNumber`
- `eth_getBlockByNumber`
- `eth_getBlockByHash`
- `eth_chainId`
- `eth_syncing`

---

### 3. Custom Stage (`custom_stage.zig`)

Shows how to implement and integrate custom sync stages.

```bash
zig build-exe examples/custom_stage.zig
./custom_stage
```

**What it demonstrates**:
- Implementing `StageInterface`
- Custom validation logic
- Stage integration
- Two example stages:
  - Timestamp validation
  - Block statistics

**Use cases**:
- Custom data indexing
- Additional validation
- Analytics and metrics
- Research and experimentation

---

### 4. Temporal State Queries (`state_queries.zig`)

Demonstrates the Domain system's time-travel capabilities.

```bash
zig build-exe examples/state_queries.zig
./state_queries
```

**What it demonstrates**:
- Domain system usage
- Historical state queries
- Time-travel debugging
- Archive node capabilities

**Query patterns**:
```zig
// Current state
const latest = try domain.getLatest("alice", tx);

// Historical state
const past = try domain.getAsOf("alice", 250, tx);
```

**Use cases**:
- Historical RPC queries
- State proof generation
- Audit and compliance
- Time-travel debugging

---

## Running All Examples

To build and run all examples:

```bash
# Build all examples
cd src/examples
for file in *.zig; do
    [ "$file" != "README.md" ] && zig build-exe "$file"
done

# Run all examples
./sync_node
./rpc_query
./custom_stage
./state_queries
```

## Integration with Main Client

These examples show isolated usage patterns. To integrate into the main client:

### Example: Adding a Custom Stage

```zig
// In your node initialization (src/node.zig)
const stages = [_]sync.StagedSync.StageDef{
    // Standard stages
    .{ .stage = .headers, .interface = headers_stage.interface },
    .{ .stage = .bodies, .interface = bodies_stage.interface },
    .{ .stage = .senders, .interface = senders_stage.interface },

    // Your custom stage
    .{ .stage = .custom, .interface = MyCustomStage.interface },

    // Continue with standard stages
    .{ .stage = .execution, .interface = execution_stage.interface },
    .{ .stage = .txlookup, .interface = txlookup_stage.interface },
    .{ .stage = .finish, .interface = finish_stage.interface },
};
```

### Example: Using Domain System in RPC

```zig
// In your RPC handler (src/rpc/eth_api.zig)
pub fn eth_getBalance(
    self: *EthApi,
    address: Address,
    block_tag: BlockTag,
) !U256 {
    // For historical queries
    if (block_tag == .number) {
        const block_num = block_tag.number;
        if (try self.domain.getAsOf(address, block_num, tx)) |balance| {
            return parseBalance(balance);
        }
    }

    // For latest
    const latest = try self.domain.getLatest(address, tx);
    return parseBalance(latest.value);
}
```

## Common Patterns

### Pattern 1: Database Transaction

```zig
var db = memdb.MemDb.init(allocator);
defer db.deinit();

var kv_db = db.database();
var tx = try kv_db.beginTx(true);
defer tx.rollback(); // Or tx.commit()

// Use tx for all operations
try domain.put(key, value, txNum, tx);
```

### Pattern 2: Stage Implementation

```zig
pub const MyStage = struct {
    pub const interface = sync.StageInterface{
        .executeFn = execute,
        .unwindFn = unwind,
    };

    pub fn execute(ctx: *sync.StageContext) !sync.StageResult {
        // Process blocks from ctx.from_block to ctx.to_block
        var blocks_processed: u64 = 0;

        // ... your logic ...

        return sync.StageResult{
            .blocks_processed = blocks_processed,
            .stage_done = true,
        };
    }

    pub fn unwind(ctx: *sync.StageContext, unwind_to: u64) !void {
        // Revert state to unwind_to block
        // ... your rollback logic ...
    }
};
```

### Pattern 3: Node Configuration

```zig
var config = NodeConfig{
    .data_dir = "/var/lib/guillotine",
    .chain_id = 1,
    .network_id = 1,
    .max_peers = 50,
    .sync_target = 1000000,
};

var node = try Node.init(allocator, config);
defer node.deinit();

try node.start();
```

## Next Steps

After running these examples:

1. **Read the source code** - Each example is heavily commented
2. **Modify parameters** - Try different configurations
3. **Combine patterns** - Use multiple techniques together
4. **Build your own** - Create custom implementations

## Additional Resources

- **Architecture docs**: `../ARCHITECTURE_FINAL.md`
- **Implementation guide**: `../IMPLEMENTATION_COMPLETE.md`
- **Quick start**: `../QUICKSTART.md`
- **Source code**: All files in `../` are heavily documented

## Getting Help

If you have questions:
1. Check the inline comments in example files
2. Read the architecture documentation
3. Look at the test files (`../test_integration.zig`, etc.)
4. Examine the main source code

## Contributing Examples

To add your own example:

1. Create a new `.zig` file in this directory
2. Follow the existing pattern (header comment, main function)
3. Document what it demonstrates
4. Add entry to this README
5. Test thoroughly

## License

Same as main project: LGPL-3.0
