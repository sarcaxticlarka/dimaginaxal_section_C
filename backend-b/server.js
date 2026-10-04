const http = require("http");

const PORT = 3002;

const server = http.createServer((req, res) => {
    res.setHeader("Content-Type", "application/json");
    res.setHeader("X-Backend", "B");
    res.setHeader("Cache-Control", "public, max-age=60");

    if (req.url === "/api/status") {
        res.writeHead(200);
        res.end(JSON.stringify({
            backend: "B",
            status: "ok"
        }));
        return;
    }

    if (req.url === "/") {
        res.writeHead(200);
        res.end(JSON.stringify({
            message: "Dimaginaxal Backend B",
            backend: "B",
            status: "running"
        }));
        return;
    }

    res.writeHead(404);
    res.end(JSON.stringify({
        error: "Not Found"
    }));
});

server.listen(PORT, "0.0.0.0", () => {
    console.log(`Backend B running on port ${PORT}`);
});
