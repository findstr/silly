# silly

[![license](https://img.shields.io/badge/license-MIT-brightgreen.svg?style=flat)](https://github.com/findstr/silly/blob/master/LICENSE)
![CI](https://github.com/findstr/silly/workflows/CI/badge.svg?branch=master)

--------

## Depend

- Debian: `apt-get install libreadline-dev`
- CentOS: `yum install readline-devel`

## Build

- `make`
- `make TLS=off` (disable TLS function)

## Running
    ./silly <main.lua> [options]

## Options
    ./silly -h

## Test

- Tests are in the test folder
- Run `./silly test/test.lua --lualib_path="test/?.lua` to test all modules

## Examples

- `examples/start.sh timer/socket/rpc/http/websocket` can run one example
- `examples/start.sh` can run all examples

## Wiki
https://github.com/findstr/silly/wiki

## Benchmark
https://github.com/findstr/silly/wiki/Benchmark

