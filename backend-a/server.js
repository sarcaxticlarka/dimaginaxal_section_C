const http = require("http");
const crypto = require("crypto");

const PORT = 3001;
const BACKEND = "A";

// Send a JSON body with an ETag. If the client already has this exact
// version (If-None-Match matches), answer 304 Not Modified with no body.
function sendJson(req, res, status, obj) {
    const body = JSON.stringify(obj);
    const etag = '"' + crypto.createHash("sha1").update(body).digest("hex").slice(0, 16) + '"';
    res.setHeader("ETag", etag);

    if (status === 200 && req.headers["if-none-match"] === etag) {
        res.writeHead(304);
        res.end();
        return;
    }

    res.writeHead(status);
    res.end(body);
}

const server = http.createServer((req, res) => {
    res.setHeader("Content-Type", "application/json");
    res.setHeader("X-Backend", BACKEND);
    res.setHeader("Cache-Control", "public, max-age=60");

    if (req.url === "/api/status") {
        return sendJson(req, res, 200, { backend: BACKEND, status: "ok" });
    }

    // Same body on both backends, so the ETag is identical on A and B
    // and a conditional request returns 304 whichever backend answers.
    if (req.url === "/api/info") {
        return sendJson(req, res, 200, { service: "dimaginaxal", version: "phase-2" });
    }

    if (req.url === "/") {
        return sendJson(req, res, 200, {
            message: "Dimaginaxal Backend " + BACKEND,
            backend: BACKEND,
            status: "running"
        });
    }

    sendJson(req, res, 404, { error: "Not Found" });
});

server.listen(PORT, "0.0.0.0", () => {
    console.log(`Backend ${BACKEND} running on port ${PORT}`);
});
