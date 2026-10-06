// Runs on Vercel at build time. If SUPABASE_URL and SUPABASE_ANON_KEY are set as
// environment variables, it writes public/config.js from them. Otherwise it keeps config.js as is.
const fs = require("fs"), path = require("path");
const E = process.env, out = path.join(__dirname, "public", "config.js");
fs.mkdirSync(path.join(__dirname, "public"), { recursive: true });
const map = { url:"SUPABASE_URL", key:"SUPABASE_ANON_KEY", logo:"LOGO_URL", brand:"BRAND_COLOR", company:"COMPANY_NAME",
  contactEmail:"CONTACT_EMAIL", address:"COMPANY_ADDRESS", grievance:"GRIEVANCE_CONTACT", law:"GOVERNING_LAW" };
if (!E.SUPABASE_URL || !E.SUPABASE_ANON_KEY) {
  console.log("No SUPABASE_URL / SUPABASE_ANON_KEY environment variables found. Using public/config.js as it is.");
  process.exit(0);
}
try {
  const role = JSON.parse(Buffer.from(E.SUPABASE_ANON_KEY.split(".")[1], "base64url").toString()).role;
  if (role === "service_role") { console.error("STOP: that is the service_role key (a secret). Use the anon public key instead."); process.exit(1); }
} catch (e) { /* not a JWT: leave it */ }
if (!/^https:\/\/[^\s"'<>]+$/.test(E.SUPABASE_URL)) { console.error("SUPABASE_URL must start with https://"); process.exit(1); }
const cfg = {};
for (const [k, env] of Object.entries(map)) if (E[env]) cfg[k] = E[env];
fs.writeFileSync(out, "window.WINSFIRE_CONFIG = " + JSON.stringify(cfg, null, 2).replace(/</g, "\\u003c") + ";\n");
console.log("public/config.js written from environment variables:", Object.keys(cfg).join(", "));
