// SPDX-License-Identifier: GPL-3.0-or-later
// 最小 CLAP 宿主（Windows 版）。加载 .clap（**单文件 DLL**）并打印插件描述、
// 音频端口、端口配置、参数数量。
//
// 与 mac 版 tools/clap-probe 的差异只有加载方式：
//   macOS：.clap 是目录包 → dlopen("<x>.clap/Contents/MacOS/<x>")
//   Windows：.clap 就是 DLL 本体 → LoadLibrary("<x>.clap")
//
// 用途：回答"插件到底有没有声明音频输入端口 / 变体的声道布局对不对"，
// 这是 Windows 上用肉眼最难确认（宿主菜单里看不出来）而 pluginval 也不细分的那一层。
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <clap/clap.h>
#include <stdio.h>
#include <string.h>

static const void *host_get_extension(const clap_host_t *h, const char *id) {
    (void)h;
    (void)id;
    return NULL;
}
static void host_request_restart(const clap_host_t *h) { (void)h; }
static void host_request_process(const clap_host_t *h) { (void)h; }
static void host_request_callback(const clap_host_t *h) { (void)h; }

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "用法: %s <plugin.clap>\n", argv[0]);
        return 1;
    }

    HMODULE lib = LoadLibraryA(argv[1]);
    if (!lib) {
        printf("LoadLibrary 失败（GetLastError=%lu）: %s\n", (unsigned long)GetLastError(), argv[1]);
        return 2;
    }
    const clap_plugin_entry_t *entry =
        (const clap_plugin_entry_t *)(void *)GetProcAddress(lib, "clap_entry");
    if (!entry) {
        printf("找不到 clap_entry 导出符号 —— 这个 .clap 没有 CLAP 入口\n");
        return 3;
    }
    if (!entry->init(argv[1])) {
        printf("entry->init 失败（%s）\n", argv[1]);
        return 4;
    }

    const clap_plugin_factory_t *fac =
        (const clap_plugin_factory_t *)entry->get_factory(CLAP_PLUGIN_FACTORY_ID);
    if (!fac) {
        printf("没有 plugin factory\n");
        return 5;
    }

    clap_host_t host = {0};
    host.clap_version = CLAP_VERSION;
    host.name = "probe";
    host.vendor = "rustomp";
    host.url = "";
    host.version = "0";
    host.get_extension = host_get_extension;
    host.request_restart = host_request_restart;
    host.request_process = host_request_process;
    host.request_callback = host_request_callback;

    uint32_t n = fac->get_plugin_count(fac);
    printf("插件数: %u\n", n);
    for (uint32_t i = 0; i < n; i++) {
        const clap_plugin_descriptor_t *d = fac->get_plugin_descriptor(fac, i);
        printf("\n[%u] id=%s\n    name=%s  vendor=%s  version=%s\n", i, d->id, d->name, d->vendor,
               d->version);
        printf("    features:");
        for (const char **f = d->features; f && *f; f++) printf(" %s", *f);
        printf("\n");

        const clap_plugin_t *p = fac->create_plugin(fac, &host, d->id);
        if (!p) {
            printf("    create_plugin 失败\n");
            continue;
        }
        p->init(p);
        const clap_plugin_audio_ports_t *ap =
            (const clap_plugin_audio_ports_t *)p->get_extension(p, CLAP_EXT_AUDIO_PORTS);
        if (!ap) {
            printf("    没有 audio-ports 扩展\n");
        } else {
            for (int in = 0; in <= 1; in++) {
                uint32_t cnt = ap->count(p, in != 0);
                printf("    %s 端口数: %u\n", in ? "输入" : "输出", cnt);
                for (uint32_t j = 0; j < cnt; j++) {
                    clap_audio_port_info_t info;
                    if (ap->get(p, j, in != 0, &info))
                        printf("      [%u] %s  channels=%u  type=%s\n", j, info.name,
                               info.channel_count, info.port_type ? info.port_type : "?");
                }
            }
        }
        const clap_plugin_audio_ports_config_t *apc =
            (const clap_plugin_audio_ports_config_t *)p->get_extension(p,
                                                                     CLAP_EXT_AUDIO_PORTS_CONFIG);
        if (apc) {
            uint32_t c = apc->count(p);
            printf("    audio-ports-config 数量: %u\n", c);
            for (uint32_t j = 0; j < c; j++) {
                clap_audio_ports_config_t cfg;
                if (apc->get(p, j, &cfg))
                    printf("      [%u] id=%u name=%s in=%u out=%u\n", j, cfg.id, cfg.name,
                           cfg.main_input_channel_count, cfg.main_output_channel_count);
            }
        } else {
            printf("    没有 audio-ports-config 扩展\n");
        }
        const clap_plugin_params_t *pp =
            (const clap_plugin_params_t *)p->get_extension(p, CLAP_EXT_PARAMS);
        if (pp) printf("    参数数: %u\n", pp->count(p));
        p->destroy(p);
    }
    entry->deinit();
    FreeLibrary(lib);
    return n > 0 ? 0 : 6;
}
