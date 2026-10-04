// Combat — shared auth helper
//
// Include after the supabase-js script tag on any page:
//   <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.js"></script>
//   <script src="auth.js"></script>
//
// Exposes window.CombatAuth with a shared Supabase client (same project
// every other page already talks to) plus small helpers, and — if the
// page has an element with id="authStatus" in its nav — automatically
// renders a "Signed in as X · Sign out" / "Sign in" widget into it, no
// per-page code required.

(function () {
  const SUPABASE_URL = "https://cguenfdcrqbduluscsel.supabase.co";
  const SUPABASE_KEY = "sb_publishable_51D_xE2j1vYOWl_0nNc4XQ_r7iAYn8x";
  const client = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  }

  async function getSession() {
    const { data } = await client.auth.getSession();
    return data.session || null;
  }

  async function getUser() {
    const session = await getSession();
    return session ? session.user : null;
  }

  async function getProfile(userId) {
    const { data } = await client.from("profiles").select("display_name").eq("id", userId).maybeSingle();
    return data;
  }

  // Creates the signed-in user's profile row if it doesn't exist yet —
  // safe to call every time after sign-in/sign-up; it no-ops if a row is
  // already there (since RLS only lets a user insert their own id, a
  // conflict on re-insert is expected and ignored).
  async function ensureProfile(userId, displayName) {
    if (!displayName) return;
    await client.from("profiles").upsert({ id: userId, display_name: displayName }, { onConflict: "id", ignoreDuplicates: true });
  }

  function onAuthChange(cb) {
    return client.auth.onAuthStateChange((_event, session) => cb(session));
  }

  async function signOut() {
    await client.auth.signOut();
  }

  async function renderAuthStatus() {
    const el = document.getElementById("authStatus");
    if (!el) return;

    const user = await getUser();
    if (!user) {
      el.innerHTML = '<a href="login.html" style="font-size:12px;color:#D4AF37;text-decoration:none;">Sign in</a>';
      return;
    }

    const profile = await getProfile(user.id);
    const name = (profile && profile.display_name) || user.email;
    el.innerHTML =
      `<span style="font-size:12px;color:#8A8A8A;">${escapeHtml(name)}</span> ` +
      `<button id="authSignOutBtn" style="font-size:11px;background:none;border:1px solid #2A2C31;color:#8A8A8A;border-radius:6px;padding:3px 8px;cursor:pointer;margin-left:8px;">Sign out</button>`;

    const btn = document.getElementById("authSignOutBtn");
    if (btn) {
      btn.addEventListener("click", async () => {
        await signOut();
        window.location.href = "login.html";
      });
    }
  }

  window.CombatAuth = {
    client,
    getSession,
    getUser,
    getProfile,
    ensureProfile,
    onAuthChange,
    signOut,
    renderAuthStatus,
    escapeHtml,
  };

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", renderAuthStatus);
  } else {
    renderAuthStatus();
  }
})();
