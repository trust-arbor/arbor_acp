// Feeds raw session/update frames to the official SDK's v1 ClientSideConnection
// and reports what its deserializer delivers to Client.sessionUpdate, so the
// interop suite can compare ArborACP's normalization with the SDK's tolerance.
//
// Usage: node acp_session_update_parity.mjs <fixtures.json>
// Prints {results, rejected}: one {delivered, update?} entry per fixture and
// the number of notifications the SDK reported as invalid.
import * as acp from "@agentclientprotocol/sdk";
import { readFile } from "node:fs/promises";

const fixtures = JSON.parse(await readFile(process.argv[2], "utf8"));

// The SDK logs each notification it cannot deserialize; count them instead.
let rejected = 0;
const consoleError = console.error;
console.error = (message, ...rest) => {
  if (message === "Error handling notification") {
    rejected += 1;
  } else {
    consoleError(message, ...rest);
  }
};
const delivered = new Map();
let markerSeen;
const marker = new Promise((resolve) => {
  markerSeen = resolve;
});

class RecordingClient {
  async sessionUpdate(params) {
    if (params.sessionId === "marker") {
      markerSeen();
    } else {
      delivered.set(params.sessionId, params.update);
    }
  }

  async requestPermission() {
    return { outcome: { outcome: "cancelled" } };
  }
}

const agentToClient = new TransformStream();
const clientToAgent = new TransformStream();
clientToAgent.readable.pipeTo(new WritableStream()).catch(() => {});

const stream = acp.ndJsonStream(clientToAgent.writable, agentToClient.readable);
new acp.ClientSideConnection(() => new RecordingClient(), stream);

const writer = agentToClient.writable.getWriter();
const encoder = new TextEncoder();

async function sendUpdate(sessionId, update) {
  const frame = { jsonrpc: "2.0", method: "session/update", params: { sessionId, update } };
  await writer.write(encoder.encode(JSON.stringify(frame) + "\n"));
}

for (const [index, update] of fixtures.entries()) {
  await sendUpdate(`fixture-${index}`, update);
}

// Notifications are handled in order, so the marker settles every fixture.
await sendUpdate("marker", {
  sessionUpdate: "agent_message_chunk",
  content: { type: "text", text: "marker" },
});

const timedOut = await Promise.race([
  marker.then(() => false),
  new Promise((resolve) => setTimeout(() => resolve(true), 5_000)),
]);

if (timedOut) {
  process.stderr.write("marker update was not delivered\n");
  process.exit(1);
}

const results = fixtures.map((_update, index) => {
  const key = `fixture-${index}`;
  return delivered.has(key) ? { delivered: true, update: delivered.get(key) } : { delivered: false };
});

process.stdout.write(JSON.stringify({ results, rejected }) + "\n");
process.exit(0);
