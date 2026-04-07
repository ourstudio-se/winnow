const std = @import("std");

pub const Asset = struct {
    content: []const u8,
    content_type: []const u8,
    cacheable: bool,
};

const assets_index_Cg0OPJ9T_js = @embedFile("frontend-dist/assets/index-Cg0OPJ9T.js");
const assets_index_Dsnhpnws_css = @embedFile("frontend-dist/assets/index-Dsnhpnws.css");
const assets_jetbrains_mono_cyrillic_wght_normal_D73BlboJ_woff2 = @embedFile("frontend-dist/assets/jetbrains-mono-cyrillic-wght-normal-D73BlboJ.woff2");
const assets_jetbrains_mono_greek_wght_normal_Bw9x6K1M_woff2 = @embedFile("frontend-dist/assets/jetbrains-mono-greek-wght-normal-Bw9x6K1M.woff2");
const assets_jetbrains_mono_latin_ext_wght_normal_DBQx_q_a_woff2 = @embedFile("frontend-dist/assets/jetbrains-mono-latin-ext-wght-normal-DBQx-q_a.woff2");
const assets_jetbrains_mono_latin_wght_normal_B9CIFXIH_woff2 = @embedFile("frontend-dist/assets/jetbrains-mono-latin-wght-normal-B9CIFXIH.woff2");
const assets_jetbrains_mono_vietnamese_wght_normal_Bt_aOZkq_woff2 = @embedFile("frontend-dist/assets/jetbrains-mono-vietnamese-wght-normal-Bt-aOZkq.woff2");
const favicon_svg = @embedFile("frontend-dist/favicon.svg");
const icons_svg = @embedFile("frontend-dist/icons.svg");
const index_html = @embedFile("frontend-dist/index.html");

const Entry = struct { path: []const u8, asset: Asset };

const assets = [_]Entry{
    .{ .path = "/", .asset = .{ .content = index_html, .content_type = "text/html", .cacheable = false } },
    .{ .path = "/assets/index-Cg0OPJ9T.js", .asset = .{ .content = assets_index_Cg0OPJ9T_js, .content_type = "application/javascript", .cacheable = true } },
    .{ .path = "/assets/index-Dsnhpnws.css", .asset = .{ .content = assets_index_Dsnhpnws_css, .content_type = "text/css", .cacheable = true } },
    .{ .path = "/assets/jetbrains-mono-cyrillic-wght-normal-D73BlboJ.woff2", .asset = .{ .content = assets_jetbrains_mono_cyrillic_wght_normal_D73BlboJ_woff2, .content_type = "font/woff2", .cacheable = true } },
    .{ .path = "/assets/jetbrains-mono-greek-wght-normal-Bw9x6K1M.woff2", .asset = .{ .content = assets_jetbrains_mono_greek_wght_normal_Bw9x6K1M_woff2, .content_type = "font/woff2", .cacheable = true } },
    .{ .path = "/assets/jetbrains-mono-latin-ext-wght-normal-DBQx-q_a.woff2", .asset = .{ .content = assets_jetbrains_mono_latin_ext_wght_normal_DBQx_q_a_woff2, .content_type = "font/woff2", .cacheable = true } },
    .{ .path = "/assets/jetbrains-mono-latin-wght-normal-B9CIFXIH.woff2", .asset = .{ .content = assets_jetbrains_mono_latin_wght_normal_B9CIFXIH_woff2, .content_type = "font/woff2", .cacheable = true } },
    .{ .path = "/assets/jetbrains-mono-vietnamese-wght-normal-Bt-aOZkq.woff2", .asset = .{ .content = assets_jetbrains_mono_vietnamese_wght_normal_Bt_aOZkq_woff2, .content_type = "font/woff2", .cacheable = true } },
    .{ .path = "/favicon.svg", .asset = .{ .content = favicon_svg, .content_type = "image/svg+xml", .cacheable = false } },
    .{ .path = "/icons.svg", .asset = .{ .content = icons_svg, .content_type = "image/svg+xml", .cacheable = false } },
    .{ .path = "/index.html", .asset = .{ .content = index_html, .content_type = "text/html", .cacheable = false } },
};

pub fn lookup(path: []const u8) ?Asset {
    for (&assets) |*entry| {
        if (std.mem.eql(u8, entry.path, path)) return entry.asset;
    }
    return null;
}
