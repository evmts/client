# JSON-RPC Server Examples

Quick reference for testing the JSON-RPC server with curl.

## Basic Queries

### Get Block Number
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

### Get Chain ID
```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "eth_chainId",
    "params": []
  }'
```

### Get Sync Status
```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "eth_syncing",
    "params": []
  }'
```

## Block Queries

### Get Block by Number
```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "eth_getBlockByNumber",
    "params": ["latest", false]
  }'
```

### Get Block by Hash
```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "eth_getBlockByHash",
    "params": ["0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef", true]
  }'
```

## Account Queries

### Get Balance
```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "eth_getBalance",
    "params": ["0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0", "latest"]
  }'
```

### Get Transaction Count (Nonce)
```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "eth_getTransactionCount",
    "params": ["0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0", "latest"]
  }'
```

### Get Code
```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "eth_getCode",
    "params": ["0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0", "latest"]
  }'
```

### Get Storage At
```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "eth_getStorageAt",
    "params": [
      "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0",
      "0x0000000000000000000000000000000000000000000000000000000000000000",
      "latest"
    ]
  }'
```

## Transaction Queries

### Get Transaction by Hash
```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "eth_getTransactionByHash",
    "params": ["0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"]
  }'
```

### Get Transaction Receipt
```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "eth_getTransactionReceipt",
    "params": ["0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"]
  }'
```

## Call & Estimate

### eth_call (Read-only execution)
```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "eth_call",
    "params": [{
      "to": "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0",
      "data": "0x70a08231000000000000000000000000742d35cc6634c0532925a3b844bc9e7595f0beb0"
    }, "latest"]
  }'
```

### Estimate Gas
```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "eth_estimateGas",
    "params": [{
      "from": "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0",
      "to": "0x1234567890123456789012345678901234567890",
      "value": "0xde0b6b3a7640000"
    }]
  }'
```

## Gas & Fees

### Get Gas Price
```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "eth_gasPrice",
    "params": []
  }'
```

### Get Max Priority Fee (EIP-1559)
```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "eth_maxPriorityFeePerGas",
    "params": []
  }'
```

### Fee History
```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "eth_feeHistory",
    "params": [4, "latest", [25, 50, 75]]
  }'
```

## Send Transaction

### Send Raw Transaction
```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "eth_sendRawTransaction",
    "params": ["0xf86c098504a817c800825208943535353535353535353535353535353535353535880de0b6b3a76400008025a028ef61340bd939bc2195fe537567866003e1a15d3c71ff63e1590620aa636276a067cbe9d8997f761aecb703304b3800ccf555c9f3dc64214b297fb1966a3b6d83"]
  }'
```

## Filters

### Create Filter
```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "eth_newFilter",
    "params": [{
      "fromBlock": "0x1",
      "toBlock": "latest",
      "address": "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0",
      "topics": []
    }]
  }'
```

### Create Block Filter
```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "eth_newBlockFilter",
    "params": []
  }'
```

### Get Filter Changes
```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "eth_getFilterChanges",
    "params": ["0x1"]
  }'
```

## Network Info

### Network Version
```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "net_version",
    "params": []
  }'
```

### Peer Count
```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "net_peerCount",
    "params": []
  }'
```

### Listening Status
```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "net_listening",
    "params": []
  }'
```

## Web3

### Client Version
```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "web3_clientVersion",
    "params": []
  }'
```

### SHA3 (Keccak-256)
```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "web3_sha3",
    "params": ["0x68656c6c6f20776f726c64"]
  }'
```

## Batch Requests

### Multiple Methods in One Call
```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '[
    {
      "jsonrpc": "2.0",
      "id": 1,
      "method": "eth_blockNumber",
      "params": []
    },
    {
      "jsonrpc": "2.0",
      "id": 2,
      "method": "eth_chainId",
      "params": []
    },
    {
      "jsonrpc": "2.0",
      "id": 3,
      "method": "eth_gasPrice",
      "params": []
    }
  ]'
```

## Debug Methods

### Trace Transaction
```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "debug_traceTransaction",
    "params": ["0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"]
  }'
```

### Trace Block by Number
```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "debug_traceBlockByNumber",
    "params": ["latest"]
  }'
```

## Error Examples

### Invalid Method
```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "eth_invalidMethod",
    "params": []
  }'
```

**Response:**
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

### Invalid Params
```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "eth_getBalance",
    "params": ["invalid_address"]
  }'
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "error": {
    "code": -32602,
    "message": "Invalid params"
  }
}
```

## Testing Tips

### Pretty Print JSON Response
```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
  | jq .
```

### Save Response to File
```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"eth_getBlockByNumber","params":["latest",true]}' \
  -o block.json
```

### Verbose Output (Debug)
```bash
curl -v -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}'
```
