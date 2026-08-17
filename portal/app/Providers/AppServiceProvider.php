<?php

namespace App\Providers;

use App\Models\Ov500\Account;
use App\Models\Ov500\BundlePackage;
use App\Models\Ov500\Carrier;
use App\Models\Ov500\Did;
use App\Models\Ov500\Ratecard;
use App\Models\Ov500\SipAccount;
use App\Models\Ov500\Tariff;
use App\Policies\AccountPolicy;
use App\Policies\BundlePolicy;
use App\Policies\CarrierPolicy;
use App\Policies\DidPolicy;
use App\Policies\RatecardPolicy;
use App\Policies\SipAccountPolicy;
use App\Policies\TariffPolicy;
use Illuminate\Pagination\Paginator;
use Illuminate\Support\Facades\Gate;
use Illuminate\Support\ServiceProvider;

class AppServiceProvider extends ServiceProvider
{
    public function register(): void
    {
        //
    }

    public function boot(): void
    {
        // Explicit policy registration — the model lives under Models\Ov500 so
        // Laravel's naming-convention auto-discovery would not find it. Explicit
        // is also safer: no policy, no access.
        Gate::policy(Carrier::class, CarrierPolicy::class);
        Gate::policy(Account::class, AccountPolicy::class);
        Gate::policy(Tariff::class, TariffPolicy::class);
        Gate::policy(Ratecard::class, RatecardPolicy::class);
        Gate::policy(Did::class, DidPolicy::class);
        Gate::policy(SipAccount::class, SipAccountPolicy::class);
        Gate::policy(BundlePackage::class, BundlePolicy::class);

        // Pagination markup. Laravel's default is the TAILWIND view, whose next/prev
        // chevrons are <svg class="w-5 h-5">. This app ships no Tailwind, so those
        // classes are inert and the SVGs expand to fill their container — giant
        // arrows on all 12 paginated pages. The bootstrap-5 view uses text arrows
        // (&lsaquo; / &rsaquo;) and no SVG at all, so sizing is correct without
        // depending on any CSS framework being loaded.
        Paginator::useBootstrapFive();

        // Scheme/port come from nginx (fastcgi_param HTTPS on + the Host header,
        // which carries :8443). No forceScheme — it dropped the non-standard port
        // from redirects, sending them to :443.
    }
}
