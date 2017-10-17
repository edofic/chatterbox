# chatterbox

Chatterbox is a simple Haskell demo program that runs in a cluster and
broadcasts messages to its peers. Upon finishing all nodes agree on the
received messages and output message count and a checksum.

## Running

Use [stack](https://docs.haskellstack.org/en/stable/README/) to build

    stack install

And then run multiple nodes, each with

    chatterbox-exe -p <unique port>

providing a unique port to each. Interface to listen on can be specified with
`-h`. All nodes need to be listed in a json file. `peers.json` is used by
default (see contents for the format) but it can be explicitly specified with
`--peer-config-file`.

Duration of the run can be configured with `--send-for` (active phase) and
`--wait-for` (sync phase, to overcome imperfect network.

Messages sent are random but can be controlled with `--with-seed`. For
debugging you can also use `--tick-duration` to control the rate and
`--verbose` to get more logs.

## Development

Use [stack](https://docs.haskellstack.org/en/stable/README/).

    stack build
    stack test
    stack repl

I also recommend [ghcid](https://github.com/ndmitchell/ghcid) for a faster
development cycle.

    ghcid -c 'stack repl --test --main-is "chatterbox:test:chatterbox-test"' -T main

## Communication protocol

Chatterbox uses a simple point-to-point communication with the goals of
partition tolerance and consistency.

It broadcasts the same message by passing it to all specified peers. This
operation is synchronous in a way; a node will be broadcasting the same message
over and over until all the peers confirm the reception, then it will move to
the next message in the series.

When a message is received it will go into _receive buffer_. If there is a
message already in the receive buffer it will get _commited_ into received
messages. Then it will be acknowledged back to the sender. If the message is
the same as the one in the buffer noting happens. Sender will store the
acknowledgements to track when to move on with the series. This means that
receiving a newer message than the one in the buffer means that all the nodes
in the cluster have seen it and it's thus safe to commit.

This part relies on there being enough network connectivity int the wait phase
at the end to receive all the acknowledgedments otherwise some nodes might
flush their receive buffers an other not. However because the buffer is limited
to a single message this means that the difference in the count of received
messages between nodes is bounded by the number of nodes (at most 1 per node)
even in the case of lack of network connectivity.

## Architecture

Chatterbox uses Cloud Haskell
([distributed-process](https://hackage.haskell.org/package/distributed-process)) for
the network layer. However it doesn't use any of the smart backends (you need
to manually specify nodes) or remote code execution. Instead each node defines
3 actors (well, `Process`es)

- `ticker` - emits a `Tick` periodically, this triggers message sending. It can
  also be pre-emptively woken up (by a message) if acknowledgements are
  received before the timeout runs out so the throughput is better.
- `worker` - listens for local messages and runs the main loop (see below),
  passing in the events
- `listener` listens for remote messages and wraps them into local messages
  before passing them to `worker`

### Main loop

A loop that runs a reducer over incoming messages and holds the current
application state. The reducer is the big function that implements the state
machine of the protocol
