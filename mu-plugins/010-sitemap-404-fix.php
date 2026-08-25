<?php

/**
 * Plugin Name: Fix — sitemap 404 on post-less sites
 * Description: Stops WordPress returning 404 for wp-sitemap.xml on a site with no published posts.
 * Version: 1.0.0
 *
 * THE BUG
 * On shuckedmusical.com, /wp-sitemap.xml returned a 404 status while still emitting
 * perfectly valid sitemap XML. Google treats a 404 sitemap as absent, so the site
 * had effectively been invisible to sitemap-based discovery since roughly 2026-08-19.
 *
 * WHY IT HAPPENS
 * `sitemap` is a registered query var, so a request to /wp-sitemap.xml is not an
 * "empty" query. WordPress therefore does NOT substitute the static front page and
 * instead runs an ordinary `post_type=post` query. Traced on staging:
 *
 *   parse_request     rule=^wp-sitemap\.xml$  vars={"sitemap":"index"}  is_404=false  200
 *   wp                                                                  is_404=TRUE   404
 *   template_redirect                                                    is_404=TRUE   404
 *
 * Between those hooks WP::handle_404() runs. It sets a 404 when the query returned no
 * posts and none of its exemptions apply. Shucked publishes 8 pages and **zero posts**,
 * and `is_home()` is false because the site uses a static front page — so every
 * exemption misses and the 404 sticks. WP_Sitemaps::render_sitemaps() then renders the
 * XML and exit()s without ever resetting the status, so the body is correct and the
 * status is wrong.
 *
 * Celebrity Autobiography is unaffected only because it still has one published post
 * (the default "Hello world!"), which makes the same query return a result.
 *
 * THE FIX
 * `pre_handle_404` is the filter core provides to short-circuit this. Bypassing it for
 * sitemap routes only is narrow, and it defers to any other plugin that got there first.
 *
 * This becomes unnecessary if the site ever publishes a post, or if core starts
 * exempting sitemap routes itself. It is safe to leave in place either way — it only
 * acts on requests that already carry a sitemap query var.
 */

declare(strict_types=1);

if (!defined('ABSPATH')) {
    exit;
}

add_filter('pre_handle_404', static function ($preempt, $wp_query) {
    // Another plugin already short-circuited; do not fight it.
    if (false !== $preempt) {
        return $preempt;
    }

    // Only sitemap routes. Everything else keeps core's normal 404 behaviour,
    // including genuine 404s on this site.
    if ($wp_query->get('sitemap') || $wp_query->get('sitemap-stylesheet')) {
        return true;
    }

    return $preempt;
}, 10, 2);
