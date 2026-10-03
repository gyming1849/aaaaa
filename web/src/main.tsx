import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter } from "react-router-dom";
import App from "./App";
import { AppProvider } from "./lib/app";
import { applyTheme } from "./lib/theme";
import "./styles.css";

try {
  applyTheme(localStorage.getItem("nl-theme"));
} catch {
  /* 浏览器禁用存储时使用系统主题 */
}

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <BrowserRouter>
      <AppProvider>
        <App />
      </AppProvider>
    </BrowserRouter>
  </StrictMode>,
);
