#!/usr/bin/env node
// Canary sink. Anything that reaches here counts as exfiltrated. Listens for HTTP requests and
// DNS-style UDP queries and appends every hit as one JSON line to $SINK_LOG. It only ever binds
// to the lab's host-side veth address.
'use strict';
const http = require('http');
const dgram = require('dgram');
const fs = require('fs');
const HOST = process.env.HOST_IP;
const LOG = process.env.SINK_LOG;
const record = (o) => { o.ts = new Date().toISOString(); fs.appendFileSync(LOG, JSON.stringify(o) + '\n'); };

http.createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    record({ kind: 'http', method: req.method, url: req.url, body: Buffer.concat(chunks).toString('utf8').slice(0, 4096) });
    res.end('ok');
  });
}).listen(+process.env.HTTP_SINK_PORT, HOST, () => console.error('http on'));

const udp = dgram.createSocket('udp4');
udp.on('message', (msg) => {
  let off = 12; const labels = [];  // skip the 12-byte DNS header, read the QNAME labels
  while (off < msg.length && msg[off] !== 0) { labels.push(msg.slice(off + 1, off + 1 + msg[off]).toString('latin1')); off += 1 + msg[off]; }
  record({ kind: 'dns', qname: labels.join('.') });
});
udp.bind(+process.env.DNS_SINK_PORT, HOST, () => console.error('dns on'));
