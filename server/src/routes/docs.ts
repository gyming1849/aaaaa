// API 文档：OpenAPI 3.1 规范（/api/openapi.json）与交互式文档页（/api/docs）
import { Router } from "express";
import { buildOpenApi } from "../openapi.ts";

export const docsRouter = Router();

docsRouter.get("/openapi.json", (req, res) => {
  res.json(buildOpenApi(`${req.protocol}://${req.get("host")}`));
});

docsRouter.get("/docs", (_req, res) => {
  res.type("html").send(`<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>食迹 NutriLog API</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5/swagger-ui.css">
<style>body{margin:0;background:#fafafa}</style></head>
<body><div id="ui"></div>
<script src="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5/swagger-ui-bundle.js"></script>
<script>SwaggerUIBundle({ url: "openapi.json", dom_id: "#ui", deepLinking: true, persistAuthorization: true });</script>
</body></html>`);
});
