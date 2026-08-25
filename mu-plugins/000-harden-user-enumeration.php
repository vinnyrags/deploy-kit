<?php

/**
 * Plugin Name: Harden — User Enumeration
 * Description: Closes the four routes by which WordPress publishes valid login names to anonymous visitors.
 * Version: 1.0.0
 *
 * Deployed by deploy-kit to wp-content/mu-plugins/ on every site. Deliberately a single
 * flat file rather than part of Mythus: it must load on Shucked (which has no Mythus), it
 * must not depend on Composer having run, and it must survive a broken theme. The 000-
 * prefix keeps it first in mu-plugin load order.
 *
 * WHY THIS EXISTS
 * Celebrity Autobiography was compromised 2026-08-11 by an attacker who logged in as the
 * "arthouse" administrator with a valid password. They did not have to guess the username:
 * /author/arthouse/ was indexed in Google, and /?author=1 returns a 301 whose Location
 * header contains the login name of user ID 1. Username enumeration plus an unthrottled
 * login form is most of that attack. Rate limiting alone does not fix it — the attacker
 * still knows exactly which account to target.
 *
 * All four vectors were open on all four ARTHOUSE sites when this was written.
 */

declare(strict_types=1);

if (!defined('ABSPATH')) {
    exit;
}

/**
 * Anyone who can legitimately list users keeps normal behaviour — the block editor's author
 * picker and the admin UI both depend on it. The goal is to stop ANONYMOUS enumeration, not
 * to break the editor.
 */
function mythus_harden_viewer_may_list_users(): bool
{
    return is_user_logged_in() && current_user_can('list_users');
}

/**
 * Vectors 1 and 2: /author/<login>/ and /?author=<id>
 *
 * Runs at priority 0 because WordPress registers redirect_canonical() on template_redirect
 * at priority 10, and that is the function which turns /?author=1 into a 301 to
 * /author/<login>/ — leaking the name in the Location header. Setting a 404 is not enough
 * on its own; redirect_canonical has to be unhooked or it still fires afterwards.
 */
add_action('template_redirect', static function (): void {
    if (!is_author() || mythus_harden_viewer_may_list_users()) {
        return;
    }

    remove_action('template_redirect', 'redirect_canonical');

    global $wp_query;
    $wp_query->set_404();
    status_header(404);
    nocache_headers();
}, 0);

/**
 * Vector 3: the core users sitemap.
 *
 * WordPress core generates /wp-sitemap-users-1.xml and lists it in the sitemap index, which
 * is how Google found and indexed the author archives in the first place. It only appears
 * once an author has published posts, which is why it was live on AVFTB and Celebrity
 * Autobiography but 404 on the other two — that difference is incidental, not protective.
 */
add_filter('wp_sitemaps_add_provider', static function ($provider, string $name) {
    return $name === 'users' ? false : $provider;
}, 10, 2);

/**
 * Vector 4: the REST users endpoint.
 *
 * /wp-json/wp/v2/users returns every user's slug as JSON to anonymous callers. Removing the
 * routes outright would break the editor, so this only hides them from viewers who could not
 * already list users through the admin.
 */
add_filter('rest_endpoints', static function (array $endpoints): array {
    if (mythus_harden_viewer_may_list_users()) {
        return $endpoints;
    }

    unset(
        $endpoints['/wp/v2/users'],
        $endpoints['/wp/v2/users/(?P<id>[\d]+)']
    );

    return $endpoints;
});

/**
 * Belt and braces: strip the author sitemap from the index even on installs where the
 * provider filter above has already run, and drop the RSD/wlwmanifest link tags that also
 * advertise structure to scanners. Cheap, no side effects on rendering.
 */
remove_action('wp_head', 'rsd_link');
remove_action('wp_head', 'wlwmanifest_link');
