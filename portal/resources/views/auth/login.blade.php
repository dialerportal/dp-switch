<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Sign in · DialerPortal</title>
    <link rel="icon" href="/brand/dialerportal-icon.svg" type="image/svg+xml">
    <link rel="alternate icon" href="/favicon.ico" sizes="any">
    <link rel="apple-touch-icon" href="/brand/dialerportal-logo-256.png">
    <style>
        *{box-sizing:border-box}
        body{margin:0;font:14px/1.5 system-ui,-apple-system,Segoe UI,Roboto,sans-serif;
             background:#0d1117;color:#1f2a37;display:flex;min-height:100vh;align-items:center;justify-content:center}
        .box{background:#fff;border-radius:10px;padding:32px;width:340px;box-shadow:0 10px 40px rgba(0,0,0,.45)}
        .brand{margin:0 0 4px;color:#0d1117}
        .brand img{display:block;width:180px;height:auto}
        .sub{color:#5f6368;margin:0 0 22px;font-size:13px}
        label{display:block;font-size:12px;color:#556;margin:0 0 4px;font-weight:600}
        input{width:100%;padding:10px;border:1px solid #cfdae4;border-radius:6px;font:inherit;margin-bottom:14px}
        .btn{width:100%;background:#0b6fa4;color:#fff;padding:11px;border:0;border-radius:6px;font:inherit;font-weight:600;cursor:pointer}
        .btn:hover{background:#095981}
        .errs{background:#fdecea;border:1px solid #d93025;color:#a50e0e;padding:9px 12px;border-radius:6px;margin-bottom:16px;font-size:13px}
        .chk{display:flex;align-items:center;gap:8px;margin-bottom:16px;font-size:13px;color:#556}
        .chk input{width:auto;margin:0}
    </style>
</head>
<body>
    <form class="box" method="POST" action="{{ route('login') }}">
        @csrf
        <h1 class="brand"><img src="/brand/dialerportal-logo.svg" alt="DialerPortal"></h1>
        <p class="sub">DP Switch · operator sign-in</p>
        @if($errors->any())
            <div class="errs">{{ $errors->first() }}</div>
        @endif
        <label for="email">Email</label>
        <input id="email" type="email" name="email" value="{{ old('email') }}" autofocus required>
        <label for="password">Password</label>
        <input id="password" type="password" name="password" required>
        <div class="chk"><input id="remember" type="checkbox" name="remember" value="1"><label for="remember" style="margin:0">Keep me signed in</label></div>
        <button class="btn" type="submit">Sign in</button>
    </form>
</body>
</html>
