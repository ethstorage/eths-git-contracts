#!/bin/bash
source .env

forge build

forge script script/Deploy.s.sol:Deploy \
  --broadcast \
  --private-key $PRIVATE_KEY \
  --rpc-url http://65.108.230.142:8545/
