#include "ggml.h"
#include "ggml-backend.h"
#include "ggml-backend-impl.h"
#include "ggml-impl.h"

#include "chip_core.h"

#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHIP_LOG(...) do { if (chip_log_level() >= 1) { fprintf(stderr, "[chip] " __VA_ARGS__); } } while (0)
#define CHIP_DBG(...) do { if (chip_log_level() >= 2) { fprintf(stderr, "[chip] " __VA_ARGS__); } } while (0)

#define CHIP_API_VERSION GGML_BACKEND_API_VERSION

static const char * chip_reg_get_name(ggml_backend_reg_t reg) {
    (void)reg;
    return "CHIP";
}

static size_t chip_reg_get_device_count(ggml_backend_reg_t reg) {
    (void)reg;
    return 1;
}

static ggml_backend_dev_t chip_reg_get_device(ggml_backend_reg_t reg, size_t index);

static void * chip_reg_get_proc_address(ggml_backend_reg_t reg, const char * name) {
    (void)reg;
    (void)name;
    return NULL;
}

static const char * chip_dev_get_name(ggml_backend_dev_t dev) {
    (void)dev;
    return "CHIP0";
}

static const char * chip_dev_get_description(ggml_backend_dev_t dev) {
    (void)dev;
    return "SRAM PIM chip simulator (Q3_K x Q8_K)";
}

static void chip_dev_get_memory(ggml_backend_dev_t dev, size_t * free, size_t * total) {
    (void)dev;
    *free = 0;
    *total = 0;
}

static enum ggml_backend_dev_type chip_dev_get_type(ggml_backend_dev_t dev) {
    (void)dev;
    return GGML_BACKEND_DEVICE_TYPE_ACCEL;
}

static void chip_dev_get_props(ggml_backend_dev_t dev, struct ggml_backend_dev_props * props) {
    (void)dev;
    memset(props, 0, sizeof(*props));
    props->name = "CHIP0";
    props->description = "SRAM PIM chip simulator (Q3_K x Q8_K)";
    props->memory_free = 0;
    props->memory_total = 0;
    props->type = GGML_BACKEND_DEVICE_TYPE_ACCEL;
    props->device_id = NULL;
}

static ggml_backend_t chip_dev_init_backend(ggml_backend_dev_t dev, const char * params);

static ggml_backend_buffer_type_t chip_dev_get_buffer_type(ggml_backend_dev_t dev) {
    (void)dev;
    typedef ggml_backend_buffer_type_t (*cpu_buft_fn)(void);
    static cpu_buft_fn fn;
    if (!fn) {
        fn = (cpu_buft_fn)dlsym(RTLD_DEFAULT, "ggml_backend_cpu_buffer_type");
    }
    return fn ? fn() : NULL;
}

static ggml_backend_buffer_type_t chip_dev_get_host_buffer_type(ggml_backend_dev_t dev) {
    (void)dev;
    return NULL;
}

static ggml_backend_buffer_t chip_dev_buffer_from_host_ptr(ggml_backend_dev_t dev, void * ptr, size_t size, size_t max_tensor_size) {
    (void)dev; (void)ptr; (void)size; (void)max_tensor_size;
    return NULL;
}

static bool chip_dev_supports_op(ggml_backend_dev_t dev, const struct ggml_tensor * op) {
    (void)dev;
    if (op->op != GGML_OP_MUL_MAT_ID) {
        return false;
    }
    const struct ggml_tensor * a = op->src[0];
    switch (a->type) {
        case GGML_TYPE_Q3_K:
        case GGML_TYPE_IQ3_XXS:
        case GGML_TYPE_IQ3_S:
        case GGML_TYPE_IQ4_XS:
            break;
        default:
            CHIP_LOG("supports_op reject: a type %d (%s) name=%s\n", (int)a->type, ggml_type_name(a->type), a->name);
            return false;
    }
    const struct ggml_tensor * b = op->src[1];
    if (b->type != GGML_TYPE_F32 && b->type != GGML_TYPE_Q8_K) {
        CHIP_LOG("supports_op reject: b type %d (%s)\n", (int)b->type, ggml_type_name(b->type));
        return false;
    }
    const struct ggml_tensor * c = op->src[2];
    if (c->type != GGML_TYPE_I32) {
        CHIP_LOG("supports_op reject: c type %d (%s)\n", (int)c->type, ggml_type_name(c->type));
        return false;
    }
    return true;
}

static bool chip_dev_supports_buft(ggml_backend_dev_t dev, ggml_backend_buffer_type_t buft) {
    (void)dev;
    typedef ggml_backend_buffer_type_t (*cpu_buft_fn)(void);
    static cpu_buft_fn fn;
    if (!fn) {
        fn = (cpu_buft_fn)dlsym(RTLD_DEFAULT, "ggml_backend_cpu_buffer_type");
    }
    return fn && buft == fn();
}

static bool chip_dev_offload_op(ggml_backend_dev_t dev, const struct ggml_tensor * op) {
    (void)dev;
    return op != NULL && op->op == GGML_OP_MUL_MAT_ID;
}

static const char * chip_backend_get_name(ggml_backend_t backend) {
    (void)backend;
    return "CHIP";
}

static void chip_backend_free(ggml_backend_t backend) {
    (void)backend;
}

static enum ggml_status chip_backend_graph_compute(ggml_backend_t backend, struct ggml_cgraph * cgraph);

static struct ggml_backend_i chip_backend_iface = {
    /* .get_name          = */ chip_backend_get_name,
    /* .free              = */ chip_backend_free,
    /* .set_tensor_async  = */ NULL,
    /* .get_tensor_async  = */ NULL,
    /* .set_tensor_2d_async = */ NULL,
    /* .get_tensor_2d_async = */ NULL,
    /* .cpy_tensor_async  = */ NULL,
    /* .synchronize       = */ NULL,
    /* .graph_plan_create = */ NULL,
    /* .graph_plan_free   = */ NULL,
    /* .graph_plan_update = */ NULL,
    /* .graph_plan_compute= */ NULL,
    /* .graph_compute     = */ chip_backend_graph_compute,
    /* .event_record      = */ NULL,
    /* .event_wait        = */ NULL,
    /* .graph_optimize    = */ NULL,
};

static struct ggml_backend chip_backend_instance;

static struct ggml_backend_reg chip_reg_instance = {
    /* .api_version = */ CHIP_API_VERSION,
    /* .iface       = */ {
        chip_reg_get_name,
        chip_reg_get_device_count,
        chip_reg_get_device,
        chip_reg_get_proc_address,
    },
    /* .context     = */ NULL,
};

static struct ggml_backend_device chip_dev_instance = {
    /* .iface   = */ {
        chip_dev_get_name,
        chip_dev_get_description,
        chip_dev_get_memory,
        chip_dev_get_type,
        chip_dev_get_props,
        chip_dev_init_backend,
        chip_dev_get_buffer_type,
        chip_dev_get_host_buffer_type,
        chip_dev_buffer_from_host_ptr,
        chip_dev_supports_op,
        chip_dev_supports_buft,
        chip_dev_offload_op,
        NULL,
        NULL,
        NULL,
    },
    /* .reg     = */ &chip_reg_instance,
    /* .context = */ NULL,
};

static ggml_backend_dev_t chip_reg_get_device(ggml_backend_reg_t reg, size_t index) {
    (void)reg;
    if (index != 0) {
        return NULL;
    }
    return &chip_dev_instance;
}

static ggml_backend_t chip_dev_init_backend(ggml_backend_dev_t dev, const char * params) {
    (void)params;
    chip_backend_instance.guid = NULL;
    chip_backend_instance.iface = chip_backend_iface;
    chip_backend_instance.device = dev;
    chip_backend_instance.context = NULL;
    return &chip_backend_instance;
}

typedef void (*vec_dot_q3_K_q8_K_fn)(int n, float * s, size_t bs, const void * vx, size_t bx, const void * vy, size_t by, int nrc);
typedef void (*quantize_row_q8_K_fn)(const float * x, void * y, int64_t k);

static void * resolve_sym_from_maps(const char * sym);

static void * resolve_sym_robust(const char * sym) {
    void * p = dlsym(RTLD_DEFAULT, sym);
    if (!p) {
        p = resolve_sym_from_maps(sym);
    }
    if (!p) {
        /* symbols live in libggml-cpu which may not be loaded yet */
        const char * names[] = { "libggml-cpu.so.0", "libggml-cpu.so", NULL };
        for (int i = 0; names[i] && !p; i++) {
            void * h = dlopen(names[i], RTLD_LAZY | RTLD_GLOBAL);
            if (h) {
                p = dlsym(RTLD_DEFAULT, sym);
            }
        }
    }
    return p;
}

static vec_dot_q3_K_q8_K_fn resolve_vec_dot(const char * sym) {
    return (vec_dot_q3_K_q8_K_fn)resolve_sym_robust(sym);
}

static void * resolve_sym_from_maps(const char * sym) {
    FILE * f = fopen("/proc/self/maps", "r");
    if (!f) {
        return NULL;
    }
    char line[1024];
    void * found = NULL;
    char last_lib[512] = "";
    while (fgets(line, sizeof(line), f)) {
        char path[512];
        if (sscanf(line, "%*s %*s %*s %*s %*s %511s", path) != 1) {
            continue;
        }
        if (!strstr(path, "libggml")) {
            continue;
        }
        if (strcmp(path, last_lib) == 0) {
            continue;
        }
        snprintf(last_lib, sizeof(last_lib), "%s", path);
        void * h = dlopen(path, RTLD_LAZY | RTLD_LOCAL | RTLD_NOLOAD);
        if (!h) {
            continue;
        }
        void * s = dlsym(h, sym);
        dlclose(h);
        if (s) {
            found = s;
            break;
        }
    }
    fclose(f);
    return found;
}

static enum ggml_status chip_backend_graph_compute(ggml_backend_t backend, struct ggml_cgraph * cgraph) {
    (void)backend;
    int ran = 0;
    for (int i = 0; i < cgraph->n_nodes; i++) {
        struct ggml_tensor * node = cgraph->nodes[i];
        if (!(node->flags & GGML_TENSOR_FLAG_COMPUTE)) {
            continue;
        }
        if (node->op == GGML_OP_MUL_MAT_ID) {
            int rc = chip_mul_mat_id(node);
            if (rc != 0) {
                CHIP_LOG("mul_mat_id failed rc=%d\n", rc);
                return GGML_STATUS_FAILED;
            }
            ran++;
        } else {
            CHIP_DBG("unexpected op=%d name=%s\n", (int)node->op, node->name ? node->name : "?");
        }
    }
    CHIP_DBG("graph_compute done: %d mul_mat_id nodes\n", ran);
    return GGML_STATUS_SUCCESS;
}

__attribute__((visibility("default")))
int ggml_backend_score(void) {
    const char * dis = getenv("CHIP_SIM_DISABLE");
    if (dis && strcmp(dis, "1") == 0) {
        return 0;
    }
    return 1;
}

__attribute__((visibility("default")))
ggml_backend_reg_t ggml_backend_init(void) {
    if (ggml_backend_score() == 0) {
        return NULL;
    }
    vec_dot_q3_K_q8_K_fn vd_q3K   = resolve_vec_dot("ggml_vec_dot_q3_K_q8_K");
    vec_dot_q3_K_q8_K_fn vd_ixxs  = resolve_vec_dot("ggml_vec_dot_iq3_xxs_q8_K");
    vec_dot_q3_K_q8_K_fn vd_is    = resolve_vec_dot("ggml_vec_dot_iq3_s_q8_K");
    vec_dot_q3_K_q8_K_fn vd_ixs   = resolve_vec_dot("ggml_vec_dot_iq4_xs_q8_K");
    if (!vd_q3K) {
        CHIP_LOG("FATAL: ggml_vec_dot_q3_K_q8_K not resolvable\n");
        return NULL;
    }
    if (getenv("CHIP_LOG_LEVEL")) {
        CHIP_LOG("vec_dot resolvers: q3_K=%p iq3_xxs=%p iq3_s=%p iq4_xs=%p\n",
            (void*)vd_q3K, (void*)vd_ixxs, (void*)vd_is, (void*)vd_ixs);
    }
    quantize_row_q8_K_fn qf = (quantize_row_q8_K_fn)resolve_sym_robust("quantize_row_q8_K");
    if (!qf) {
        CHIP_LOG("FATAL: quantize_row_q8_K not resolvable\n");
        return NULL;
    }
    if (chip_core_init(vd_q3K, vd_ixxs, vd_is, vd_ixs, qf) != 0) {
        return NULL;
    }
    CHIP_LOG("registered (api_version=%d)\n", CHIP_API_VERSION);
    return &chip_reg_instance;
}
