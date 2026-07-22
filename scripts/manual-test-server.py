#!/usr/bin/env python3

import base64
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


PAGE = """<!doctype html>
<html lang="ru">
<meta charset="utf-8">
<title>Browser manual test</title>
<style>
  body { font: 16px system-ui; max-width: 720px; margin: 60px auto; line-height: 1.5; }
  button, a { display: inline-block; margin: 8px 8px 8px 0; padding: 10px 14px; }
  video { display: block; width: 560px; max-width: 100%; margin-top: 20px; background: #111; }
  #status { white-space: pre-wrap; }
</style>
<h1>Browser: download и camera</h1>
<p><a href="/download" download>Быстрая тестовая загрузка</a></p>
<p><a href="/download-slow" download>Медленная загрузка для проверки progress bubble</a></p>
<button id="camera">Включить камеру</button>
<button id="stop" disabled>Остановить камеру</button>
<button id="prompt">Проверить JavaScript prompt</button>
<a href="/auth">Проверить HTTP Basic auth</a>
<p><a href="mailto:browser-test@example.com">Проверить подтверждение mailto</a></p>
<p id="status">Ожидание теста</p>
<video id="preview" autoplay muted playsinline></video>
<script>
let stream;
const status = document.querySelector('#status');
const stop = document.querySelector('#stop');
document.querySelector('#camera').onclick = async () => {
  try {
    stream = await navigator.mediaDevices.getUserMedia({video: true});
    document.querySelector('#preview').srcObject = stream;
    stop.disabled = false;
    status.textContent = 'Камера работает';
  } catch (error) {
    status.textContent = `${error.name}: ${error.message}`;
  }
};
stop.onclick = () => {
  stream?.getTracks().forEach(track => track.stop());
  document.querySelector('#preview').srcObject = null;
  stop.disabled = true;
  status.textContent = 'Камера остановлена';
};
document.querySelector('#prompt').onclick = () => {
  const value = window.prompt('Введите тестовое значение', 'Browser');
  status.textContent = value === null ? 'Prompt отменён' : `Prompt вернул: ${value}`;
};
</script>
</html>
""".encode()

DOWNLOAD = "Browser WKDownload работает.\n".encode()
FAVICON = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9ZlC8AAAAASUVORK5CYII="
)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/download-slow":
            chunk = b"Browser download progress test.\n" * 2048
            chunk_count = 80
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header(
                "Content-Disposition",
                'attachment; filename="browser-download-progress.txt"',
            )
            self.send_header("Content-Length", str(len(chunk) * chunk_count))
            self.end_headers()
            try:
                for _ in range(chunk_count):
                    self.wfile.write(chunk)
                    self.wfile.flush()
                    time.sleep(0.05)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return

        if self.path == "/auth":
            expected = "Basic " + base64.b64encode(b"browser:test").decode()
            if self.headers.get("Authorization") != expected:
                self.send_response(401)
                self.send_header("WWW-Authenticate", 'Basic realm="Browser manual test"')
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            body = "HTTP Basic authentication работает.\n".encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/download":
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header(
                "Content-Disposition",
                'attachment; filename="browser-download-test.txt"',
            )
            self.send_header("Content-Length", str(len(DOWNLOAD)))
            self.end_headers()
            self.wfile.write(DOWNLOAD)
            return

        if self.path == "/favicon.ico":
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(FAVICON)))
            self.end_headers()
            self.wfile.write(FAVICON)
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(PAGE)))
        self.end_headers()
        self.wfile.write(PAGE)


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 8765), Handler)
    print("Manual test page: http://localhost:8765", flush=True)
    server.serve_forever()
