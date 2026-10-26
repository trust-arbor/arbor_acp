// Validates ArborACP MCP-over-ACP frames against the ACP SDK 1.9 v1 zod
// schemas. The SDK's v1 connection classes do not implement this transport,
// and its draft-v2 connection API speaks protocol version 2 only. ArborACP
// speaks protocol version 1, so this checks the encoded JSON instead of
// opening a live draft-v2 connection. The v1 and draft-v2 wire shapes match;
// the v2 capability object does not, and this script does not accept it.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import {
  zAgentRequest,
  zClientNotification,
  zClientResponse,
  zMcpCapabilities,
  zMcpError,
  zMcpRequestId,
  zMcpServer,
  zMcpServerAcp,
  zMcpServerAcpId,
  zMessageMcpNotification,
  zMessageMcpRequest,
  zMessageMcpResponse,
} from "./node_modules/@agentclientprotocol/sdk/dist/schema/zod.gen.js";
import { zMcpCapabilities as zMcpCapabilitiesV2 } from "./node_modules/@agentclientprotocol/sdk/dist/v2/schema/zod.gen.js";

const source = process.argv[2];
if (!source) {
  throw new Error("usage: node mcp_over_acp_schema.mjs <frames.json>");
}
const frames = JSON.parse(await readFile(source, "utf8"));

assert.equal(zMcpServerAcpId.safeParse("").success, true);
assert.equal(zMcpRequestId.safeParse("").success, true);

const caps = must(zMcpCapabilities, {}, "default capabilities");
assert.equal(caps.http, false);
assert.equal(caps.sse, false);
assert.equal(caps.acp, false);
assert.equal(must(zMcpCapabilities, { acp: true }, "acp true").acp, true);
assert.equal(must(zMcpCapabilities, { acp: {} }, "acp object").acp, false);

const v2 = zMcpCapabilitiesV2.safeParse({ acp: true });
assert.equal(v2.success, true);
assert.equal(v2.data.acp, undefined);
assert.deepEqual(must(zMcpCapabilitiesV2, { acp: {} }, "v2 acp object").acp, {});

const server = must(zMcpServer, frames.server, "mcp server");
assert.deepEqual(server, frames.server);
assert.deepEqual(must(zMcpServerAcp, frames.server, "acp server"), {
  name: frames.server.name,
  serverId: frames.server.serverId,
  _meta: frames.server._meta,
});

const request = must(zAgentRequest, frames.request, "mcp request");
assert.equal(request.method, "mcp/message");
assert.equal(request.id, frames.request.id);
assert.deepEqual(
  request.params,
  must(zMessageMcpRequest, frames.request.params, "request params"),
);

const notification = must(zClientNotification, frames.notification, "mcp notification");
assert.equal(notification.method, "mcp/message");
assert.equal(Object.hasOwn(notification, "id"), false);
assert.deepEqual(
  notification.params,
  must(zMessageMcpNotification, frames.notification.params, "notification params"),
);

assert.equal(zClientResponse.safeParse(frames.resultNull).success, true);
assert.equal(zClientResponse.safeParse(frames.resultObject).success, true);
assert.equal(zClientResponse.safeParse(frames.mcpError).success, true);

const nullResult = must(zMessageMcpResponse, frames.resultNull.result, "null result");
assert.equal(nullResult.result, null);
assert.equal(Object.hasOwn(nullResult, "error"), false);

const objectResult = must(zMessageMcpResponse, frames.resultObject.result, "object result");
assert.deepEqual(objectResult.result, frames.resultObject.result.result);

const innerError = must(zMessageMcpResponse, frames.mcpError.result, "inner error");
assert.deepEqual(innerError.error, must(zMcpError, frames.mcpError.result.error, "mcp error"));
assert.equal(innerError.error.data, null);

const preferred = must(
  zMessageMcpResponse,
  { result: { ok: true }, error: { code: 1, message: "ignored" } },
  "result preferred",
);
assert.deepEqual(preferred, { result: { ok: true } });

assert.deepEqual(must(zMcpError, { code: 1, message: "", data: null }, "null data"), {
  code: 1,
  message: "",
  data: null,
});
assert.equal(Object.hasOwn(must(zMcpError, { code: 1, message: "m" }, "omitted data"), "data"), false);
assert.equal(must(zMcpError, { code: 1, message: "m", extra: true }, "loose error").extra, true);
assert.equal(zMcpError.safeParse({ code: -2147483648, message: "m" }).success, true);
assert.equal(zMcpError.safeParse({ code: 2147483647, message: "m" }).success, true);
assert.equal(zMcpError.safeParse({ code: 2147483648, message: "m" }).success, false);
assert.equal(zMcpError.safeParse({ code: -2147483649, message: "m" }).success, false);

process.stdout.write(`${JSON.stringify({ ok: true })}\n`);

function must(schema, value, label) {
  const parsed = schema.safeParse(value);
  if (!parsed.success) {
    throw new Error(`${label}: ${parsed.error.message}`);
  }
  return parsed.data;
}
