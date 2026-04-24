from web3 import Web3
from eth_account import Account

w3 = Web3(Web3.HTTPProvider("http://localhost:30545"))
print("Block:", w3.eth.block_number)
print("BaseFee:", w3.eth.get_block('latest').get('baseFeePerGas'))

Account.enable_unaudited_hdwallet_features()
mnemonic = "sleep moment list remain like wall lake industry canvas wonder ecology elite duck salad naive syrup frame brass utility club odor country obey pudding"
sender = Account.from_mnemonic(mnemonic, account_path="m/44'/60'/0'/0/0")
receiver = Account.from_mnemonic(mnemonic, account_path="m/44'/60'/0'/0/1")

tx = {
    'to': receiver.address,
    'value': w3.to_wei(1, 'ether'),
    'gas': 210000,
    'gasPrice': 10000,
    'nonce': w3.eth.get_transaction_count(sender.address),
    'chainId': 32382,
}
signed = sender.sign_transaction(tx)
tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
print(f"Tx sent: {tx_hash.hex()}")
receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=30)
print(f"Status: {'SUCCESS' if receipt['status'] == 1 else 'FAILED'}")
print(f"Effective gas price: {receipt['effectiveGasPrice']}")