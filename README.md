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

## Configuration

- `daemon`, 1 --> run as daemon, 0 --> normal
- `bootstrap`, lua entry file
- `lualib_path`, will append the package.path (in luaVM)
- `lualib_cpath`, will append the package.cpath (int luaVM)
- `logpath`, if running in daemon mode, all print messages will be written to the  `[logpath]/silly-[pid].log` file
- `loglevel`, is used to control the log level limits, it can be set to `debug`, `info`, `warn`, or `error`, default is `info`
- `pidfile`,  if running in daemon mode, `pidfile` will used by run only once in a system

## Running
    ./silly <config>

## Test

- Tests are in the test folder
- Run `./silly test/test.conf` to test all modules

## Examples

- `examples/start.sh timer/socket/rpc/http/websocket` can run one example
- `examples/start.sh` can run all examples

## Wiki
https://github.com/findstr/silly/wiki

## Benchmark
https://github.com/findstr/silly/wiki/Benchmark

