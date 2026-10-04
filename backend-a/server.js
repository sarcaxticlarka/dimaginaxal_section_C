const http = require("http");

const PORT = 3001;

const server = http.createServer((req, res) => {
    res.setHeader("Content-Type", "application/json");
    res.setHeader("X-Backend", "A");
    res.setHeader("Cache-Control", "public, max-age=60");

    if (req.url === "/api/status") {
        res.writeHead(200);
        res.end(JSON.stringify({
            backend: "A",
            status: "ok"
        }));
        return;
    }

    if (req.url === "/") {
        res.writeHead(200);
        res.end(JSON.stringify({
            message: "Dimaginaxal Backend A",
            backend: "A",
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
    console.log(`Backend A running on port ${PORT}`);
});
