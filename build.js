// Runs on Vercel at build time.
const fs = require("fs"), path = require("path");
const E = process.env;

const publicDir = path.join(__dirname, "public");
fs.mkdirSync(publicDir, { recursive: true });

// Copy all static files to public
const filesToCopy = fs.readdirSync(__dirname).filter(f =>
  f.endsWith(".html") || f.endsWith(".js") && f!== "build.js" || f.endsWith(".css") || f === "assets"
);

fs.readdirSync(__dirname).forEach(file => {
  if (file === "public" || file === "node_modules" || file.startsWith(".") || file === "vercel.json") return;
  const src = path.join(__dirname, file);
  const dest = path.join(publicDir, file);
  try {
    if (fs.lstatSync(src).isDirectory()) {
      fs.cpSync(src, dest, { recursive: true });
    } else {
      fs.copyFileSync(src, dest);
    }
  } catch(e) {}
});

// Now handle config
const out = path.join(__dirname, "public", "config.js");
const map = { url:"SUPABASE_URL", key:"SUPABASE_ANON_KEY", logo:"LOGO_URL", brand:"BRAND_COLOR", company:"COMPANY_NAME", contactEmail:"CONTACT_EMAIL", address:"COMPANY_ADDRESS", grievance:"GRIEVANCE_CONTACT", law:"GOVERNING_LAW" };

if (!E.SUPABASE_URL ||!E.SUPABASE_ANON_KEY) {
  console.log("No SUPABASE env found. Using public/config.js as it is.");
  if (!fs.existsSync(out)) {
    fs.writeFileSync(out, "window.WINSFIRE_CONFIG = {};");
  }
  process.exit(0);
}

let configContent = "";
try { configContent = fs.readFileSync(out, "utf8"); } catch(e) { configContent = "window.WINSFIRE_CONFIG = {};"; }

let cfg = {};
try {
  const m = configContent.match(/window\.WINSFIRE_CONFIG\s*=\s*(\{[\s\S]*?\});/);
  if (m) cfg = eval("(" + m[1] + ")");
} catch(e) {}

for (const [k, envName] of Object.entries(map)) {
  if (E[envName]) cfg[k] = E[envName];
}

fs.writeFileSync(out, "window.WINSFIRE_CONFIG = " + JSON.stringify(cfg, null, 2) + ";");
console.log("Built public/config.js");