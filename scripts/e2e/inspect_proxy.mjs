// A recording HTTP proxy for end-to-end tests (issue #1705).
//
// Sits between a Cloudflare Quick Tunnel and the local Phoenix server and
// writes every request and response to a log: method, path, headers, body.
// That is the one thing a tunnel cannot tell you and the reason a CardDAV
// diagnosis needs it — "does the client ever send an Authorization header"
// is not a question the server log can answer, because a request that never
// arrives leaves no trace.
//
// Node's built-in http only: this runs from a checkout with no npm install,
// and an end-to-end harness nobody can start is not a harness.
//
// **Credentials are never written.** An Authorization header is logged as its
// scheme plus the user name in front of the colon — enough to see whether the
// client authenticated and as whom, and nothing that could be replayed.

import http from 'node:http';
import fs from 'node:fs';
import zlib from 'node:zlib';

const listen = Number(process.env.PROXY_PORT || 4038);
const target = Number(process.env.APP_PORT || 4037);
const logPath = process.env.PROXY_LOG || '/tmp/vutuv-e2e-proxy.log';
// Bodies are logged whole up to this; a vCard collection can be megabytes and
// nobody reads that in a log.
const maxBody = Number(process.env.PROXY_MAX_BODY || 4000);

const out = fs.createWriteStream(logPath, { flags: 'a' });
const write = (text) => out.write(text + '\n');

function safeHeaders(headers) {
  const copy = { ...headers };
  if (copy.authorization) copy.authorization = describeAuth(copy.authorization);
  if (copy.cookie) copy.cookie = '[redacted]';
  return copy;
}

// "Basic <base64>" → "Basic user=smoke-carddavsmoke (secret redacted)".
function describeAuth(value) {
  const [scheme, payload] = value.split(' ', 2);
  if (scheme?.toLowerCase() !== 'basic' || !payload) return `${scheme} [redacted]`;
  try {
    const user = Buffer.from(payload, 'base64').toString('utf8').split(':', 1)[0];
    return `Basic user=${user} (secret redacted)`;
  } catch {
    return 'Basic [undecodable]';
  }
}

// Answers come back compressed, and a log full of gzip is a log nobody reads.
function printable(buffer, encoding) {
  let decoded = buffer;

  try {
    if (encoding === 'gzip') decoded = zlib.gunzipSync(buffer);
    else if (encoding === 'deflate') decoded = zlib.inflateSync(buffer);
    else if (encoding === 'br') decoded = zlib.brotliDecompressSync(buffer);
    else if (encoding === 'zstd' && zlib.zstdDecompressSync) {
      decoded = zlib.zstdDecompressSync(buffer);
    }
  } catch {
    return `[${encoding} body, ${buffer.length} bytes, could not be decoded]`;
  }

  const text = decoded.toString('utf8');
  return decoded.length > maxBody ? text.slice(0, maxBody) + `… [${decoded.length} bytes]` : text;
}

let counter = 0;

const server = http.createServer((req, res) => {
  const id = ++counter;
  const chunks = [];

  req.on('data', (chunk) => chunks.push(chunk));
  req.on('end', () => {
    const body = Buffer.concat(chunks);
    const stamp = new Date().toISOString();

    write(`\n━━━ #${id} ${stamp} ▶ ${req.method} ${req.url}`);
    write(JSON.stringify(safeHeaders(req.headers), null, 2));
    if (body.length) write('--- body ---\n' + printable(body, req.headers['content-encoding']));

    const upstream = http.request(
      { host: '127.0.0.1', port: target, method: req.method, path: req.url, headers: req.headers },
      (answer) => {
        const answerChunks = [];
        answer.on('data', (chunk) => answerChunks.push(chunk));
        answer.on('end', () => {
          const answerBody = Buffer.concat(answerChunks);
          write(`━━━ #${id} ◀ ${answer.statusCode}`);
          write(JSON.stringify(safeHeaders(answer.headers), null, 2));
          if (answerBody.length) {
            write('--- body ---\n' + printable(answerBody, answer.headers['content-encoding']));
          }
        });

        res.writeHead(answer.statusCode, answer.headers);
        answer.pipe(res);
      },
    );

    upstream.on('error', (error) => {
      write(`━━━ #${id} ◀ upstream error: ${error.message}`);
      res.writeHead(502).end('upstream unreachable');
    });

    if (body.length) upstream.write(body);
    upstream.end();
  });
});

server.listen(listen, '127.0.0.1', () => {
  write(`\n════════ proxy up: :${listen} → :${target} ════════`);
  console.log(`inspect proxy :${listen} → :${target}, log ${logPath}`);
});
