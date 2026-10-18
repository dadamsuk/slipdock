// A stand-in OpenAI-compatible model server for the e2e scripts: no key, no
// network. Chat answers with the JSON in $FAKE_AI_REPLY (default: a
// handoff draft), after $FAKE_AI_DELAY_MS; embeddings are zeros; models is
// one model. Each chat request's last message is appended to $FAKE_AI_LOG.
//
//   node tools/e2e/fake-ai.mjs <port>
import http from 'node:http'
import fs from 'node:fs'

const port = Number(process.argv[2] || 4199)
const reply = process.env.FAKE_AI_REPLY ||
  JSON.stringify({ next_step: 'Fix the webhook signature check', body: 'State: checkout done\nGotchas: staging secret differs' })
const delay = Number(process.env.FAKE_AI_DELAY_MS || 600)

http.createServer((req, res) => {
  let raw = ''
  req.on('data', (c) => { raw += c })
  req.on('end', () => {
    const body = raw ? JSON.parse(raw) : {}
    const json = (obj) => { res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify(obj)) }
    if (req.url.endsWith('/models')) return json({ data: [{ id: 'fake/model' }] })
    if (req.url.endsWith('/embeddings')) {
      const inputs = Array.isArray(body.input) ? body.input : [body.input]
      return json({ data: inputs.map((_, i) => ({ index: i, embedding: new Array(768).fill(0).map((_, j) => (j === i % 768 ? 1 : 0)) })) })
    }
    if (process.env.FAKE_AI_LOG) {
      const last = (body.messages || []).slice(-1)[0]
      fs.appendFileSync(process.env.FAKE_AI_LOG, (last && last.content) + '\n----\n')
    }
    setTimeout(() => json({
      id: 'fake', object: 'chat.completion', model: 'fake/model',
      choices: [{ index: 0, finish_reason: 'stop', message: { role: 'assistant', content: reply } }],
      usage: { prompt_tokens: 1, completion_tokens: 1 },
    }), delay)
  })
}).listen(port, '127.0.0.1')
