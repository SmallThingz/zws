import process from 'node:process';
import { WebSocket, WebSocketServer } from 'ws';

function parseArgs(argv) {
  const args = {
    mode: null,
    port: 9100,
    url: 'ws://127.0.0.1:9100/',
    compression: false,
  };
  for (const arg of argv) {
    if (arg === 'server' || arg === 'client') {
      args.mode = arg;
    } else if (arg === '--compression') {
      args.compression = true;
    } else if (arg.startsWith('--port=')) {
      args.port = Number(arg.slice('--port='.length));
    } else if (arg.startsWith('--url=')) {
      args.url = arg.slice('--url='.length);
    } else if (arg === '--help') {
      console.log('ws_peer.mjs [server|client] [--port=9100] [--url=ws://127.0.0.1:9100/] [--compression]');
      process.exit(0);
    } else {
      throw new Error(`unknown arg: ${arg}`);
    }
  }
  if (!args.mode) {
    throw new Error('missing mode: server or client');
  }
  return args;
}

function waitForEvent(target, event) {
  return new Promise((resolve, reject) => {
    const onEvent = (...values) => {
      cleanup();
      resolve(values);
    };
    const onError = (err) => {
      cleanup();
      reject(err);
    };
    const cleanup = () => {
      target.off(event, onEvent);
      target.off('error', onError);
    };
    target.once(event, onEvent);
    target.once('error', onError);
  });
}

async function runClient(args) {
  const ws = new WebSocket(args.url, {
    perMessageDeflate: args.compression,
  });
  await waitForEvent(ws, 'open');

  const textPayload = 'zwebsocket interop text payload with enough repetition to exercise permessage-deflate';
  ws.send(textPayload);
  {
    const [data, isBinary] = await waitForEvent(ws, 'message');
    if (isBinary || data.toString() !== textPayload) {
      throw new Error('text echo mismatch');
    }
  }

  const binaryPayload = Buffer.alloc(256);
  for (let i = 0; i < binaryPayload.length; i += 1) {
    binaryPayload[i] = (i * 13 + 7) & 0xff;
  }
  ws.send(binaryPayload, { binary: true });
  {
    const [data, isBinary] = await waitForEvent(ws, 'message');
    const received = Buffer.isBuffer(data) ? data : Buffer.from(data);
    if (!isBinary || !received.equals(binaryPayload)) {
      throw new Error('binary echo mismatch');
    }
  }

  ws.close(1000);
  await waitForEvent(ws, 'close');
}

function runServer(args) {
  const server = new WebSocketServer({
    port: args.port,
    perMessageDeflate: args.compression,
  });
  server.on('connection', (ws) => {
    ws.on('message', (data, isBinary) => {
      ws.send(data, { binary: isBinary });
    });
  });
}

const args = parseArgs(process.argv.slice(2));
if (args.mode === 'server') {
  runServer(args);
} else {
  runClient(args).catch((err) => {
    console.error(err.stack || String(err));
    process.exit(1);
  });
}
