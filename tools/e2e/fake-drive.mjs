// A stand-in for the bits of Google the meeting player uses (W-1690), for
// tools/e2e/meeting-player.sh: the token endpoint, a folder "Rec" holding
// meeting.wav (70 seconds of tone, made here), and the file's bytes with
// Range honoured the way Drive honours it.
//
//   node tools/e2e/fake-drive.mjs <port>
import http from 'node:http'

const port = Number(process.argv[2] || 4113)

// 8 kHz, 8-bit mono PCM: small, and every browser plays WAV.
function wav(seconds) {
  const rate = 8000
  const n = rate * seconds
  const buf = Buffer.alloc(44 + n)
  buf.write('RIFF', 0); buf.writeUInt32LE(36 + n, 4); buf.write('WAVE', 8)
  buf.write('fmt ', 12); buf.writeUInt32LE(16, 16); buf.writeUInt16LE(1, 20); buf.writeUInt16LE(1, 22)
  buf.writeUInt32LE(rate, 24); buf.writeUInt32LE(rate, 28); buf.writeUInt16LE(1, 32); buf.writeUInt16LE(8, 34)
  buf.write('data', 36); buf.writeUInt32LE(n, 40)
  for (let i = 0; i < n; i++) buf[44 + i] = 128 + Math.round(40 * Math.sin((2 * Math.PI * 440 * i) / rate))
  return buf
}

const audio = wav(70)
const files = [
  { id: 'fold', name: 'Rec', mimeType: 'application/vnd.google-apps.folder', parents: ['root'] },
  { id: 'aud', name: 'meeting.wav', mimeType: 'audio/wav', size: String(audio.length), parents: ['fold'] },
]

const json = (res, status, body) => {
  res.writeHead(status, { 'content-type': 'application/json' })
  res.end(JSON.stringify(body))
}

http.createServer((req, res) => {
  const url = new URL(req.url, 'http://x')
  if (url.pathname === '/token') return json(res, 200, { access_token: 'e2e-access', expires_in: 3599 })
  if (url.pathname === '/drive/v3/files') {
    const [, name, parent] = url.searchParams.get('q').match(/^name = '((?:[^'\\]|\\.)*)' and '([^']*)' in parents/)
    const clean = name.replace(/\\(.)/g, '$1')
    return json(res, 200, { files: files.filter((f) => f.name === clean && f.parents.includes(parent)) })
  }
  const m = url.pathname.match(/^\/drive\/v3\/files\/(.+)$/)
  const file = m && files.find((f) => f.id === decodeURIComponent(m[1]))
  if (!file) return json(res, 404, { error: { code: 404 } })
  if (url.searchParams.get('alt') !== 'media') return json(res, 200, file)

  const range = (req.headers.range || '').match(/^bytes=(\d+)-(\d*)$/)
  if (range) {
    const first = Number(range[1])
    const last = range[2] === '' ? audio.length - 1 : Math.min(Number(range[2]), audio.length - 1)
    res.writeHead(206, {
      'content-type': 'audio/wav', 'accept-ranges': 'bytes',
      'content-range': `bytes ${first}-${last}/${audio.length}`, 'content-length': last - first + 1,
    })
    return res.end(audio.subarray(first, last + 1))
  }
  res.writeHead(200, { 'content-type': 'audio/wav', 'accept-ranges': 'bytes', 'content-length': audio.length })
  res.end(audio)
}).listen(port, '127.0.0.1')
