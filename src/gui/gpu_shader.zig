const std = @import("std");
const zopengl = @import("zopengl");
const gl = zopengl.bindings;

/// OpenGL 3.3 Core 离屏 FBO 真实片段着色器 GPU 压力引擎（V2.2）。
/// 设计原则（低负担、不卡桌面）：
/// 1. 懒初始化：仅当用户主动启动 GPU 烤机或综合联烤时才分配 FBO/纹理/Shader，测试停止后立即释放，平时零显存零 GPU 占用；
/// 2. 三档安全强度（温和 / 均衡 / 高负载），默认「均衡」档，单帧 GPU 执行时间严格控制在安全窗口内，绝不触发 Windows TDR（2 秒超时）或导致桌面卡顿；
/// 3. 离屏渲染结果可直接通过 zgui.image 嵌入测试卡片实时预览。
pub const GpuStressShader = struct {
    fbo: u32 = 0,
    tex: u32 = 0,
    vao: u32 = 0,
    program: u32 = 0,
    u_time: i32 = -1,
    u_res: i32 = -1,
    u_steps: i32 = -1,
    width: i32 = 0,
    height: i32 = 0,
    steps: i32 = 56,
    intensity: u8 = 255,
    ready: bool = false,
    failed: bool = false,

    const VERT_SRC: [:0]const u8 =
        \\#version 330 core
        \\out vec2 v_uv;
        \\void main() {
        \\    vec2 pos = vec2((gl_VertexID == 1) ? 3.0 : -1.0, (gl_VertexID == 2) ? 3.0 : -1.0);
        \\    v_uv = pos * 0.5 + 0.5;
        \\    gl_Position = vec4(pos, 0.0, 1.0);
        \\}
    ;

    const FRAG_SRC: [:0]const u8 =
        \\#version 330 core
        \\in vec2 v_uv;
        \\out vec4 frag_color;
        \\uniform float u_time;
        \\uniform vec2 u_res;
        \\uniform int u_steps;
        \\
        \\float mapScene(vec3 p, float t) {
        \\    float c = cos(t * 0.7), s = sin(t * 0.7);
        \\    p.xz = mat2(c, -s, s, c) * p.xz;
        \\    p.xy = mat2(cos(t * 0.4), -sin(t * 0.4), sin(t * 0.4), cos(t * 0.4)) * p.xy;
        \\    vec2 q = vec2(length(p.xz) - 0.85, p.y);
        \\    float torus = length(q) - 0.30;
        \\    float ripples = 0.045 * sin(p.x * 9.0 + t * 2.5) * cos(p.y * 9.0 - t * 2.0) * sin(p.z * 9.0);
        \\    return torus + ripples;
        \\}
        \\
        \\void main() {
        \\    vec2 p = (gl_FragCoord.xy - 0.5 * u_res) / max(u_res.y, 1.0);
        \\    vec3 ro = vec3(0.0, 0.0, 2.35);
        \\    vec3 rd = normalize(vec3(p, -1.55));
        \\    float d_acc = 0.0;
        \\    float glow = 0.0;
        \\    bool hit = false;
        \\    int max_s = clamp(u_steps, 24, 128);
        \\    for (int i = 0; i < 128; i++) {
        \\        if (i >= max_s) break;
        \\        vec3 pos = ro + rd * d_acc;
        \\        float d = mapScene(pos, u_time);
        \\        glow += 0.015 / (0.04 + abs(d));
        \\        if (d < 0.0025) { hit = true; break; }
        \\        d_acc += d * 0.72;
        \\        if (d_acc > 6.0) break;
        \\    }
        \\    // 附加浮点分形迭代确保稳定可控的 ALU 着色器负载
        \\    vec2 z = p * 1.45;
        \\    vec2 c_val = vec2(0.355 + 0.08 * sin(u_time * 0.6), 0.355 + 0.08 * cos(u_time * 0.5));
        \\    float iter = 0.0;
        \\    int f_steps = max_s / 2;
        \\    for (int j = 0; j < 64; j++) {
        \\        if (j >= f_steps) break;
        \\        z = vec2(z.x * z.x - z.y * z.y, 2.0 * z.x * z.y) + c_val;
        \\        if (dot(z, z) > 8.0) break;
        \\        iter += 1.0;
        \\    }
        \\    float f = iter / float(max(f_steps, 1));
        \\    vec3 bg = mix(vec3(0.06, 0.09, 0.15), vec3(0.11, 0.24, 0.42), f);
        \\    vec3 col = bg + vec3(0.15, 0.62, 0.98) * min(glow * 0.22, 1.2);
        \\    if (hit) {
        \\        vec3 hp = ro + rd * d_acc;
        \\        vec3 base = 0.5 + 0.5 * cos(u_time + hp.xyx + vec3(0.0, 2.0, 4.0));
        \\        col = mix(col, base * 1.05, 0.78);
        \\    }
        \\    frag_color = vec4(clamp(col, 0.0, 1.0), 1.0);
        \\}
    ;

    pub fn ensureReady(self: *GpuStressShader, intensity: u8) bool {
        if (self.failed) return false;
        const clamped = @min(intensity, 2);
        if (self.ready and self.intensity == clamped) return true;

        self.deinit();
        self.intensity = clamped;

        // 三档安全分辨率与迭代步数（默认 1 = 均衡，流畅不卡桌面）
        switch (clamped) {
            0 => {
                self.width = 480;
                self.height = 270;
                self.steps = 32;
            },
            1 => {
                self.width = 768;
                self.height = 432;
                self.steps = 56;
            },
            else => {
                self.width = 1024;
                self.height = 576;
                self.steps = 96;
            },
        }

        const vs = compileShader(gl.VERTEX_SHADER, VERT_SRC) orelse {
            self.failed = true;
            return false;
        };
        defer gl.deleteShader(vs);
        const fs = compileShader(gl.FRAGMENT_SHADER, FRAG_SRC) orelse {
            self.failed = true;
            return false;
        };
        defer gl.deleteShader(fs);

        const prog = gl.createProgram();
        gl.attachShader(prog, vs);
        gl.attachShader(prog, fs);
        gl.linkProgram(prog);
        var linked: i32 = 0;
        gl.getProgramiv(prog, gl.LINK_STATUS, &linked);
        if (linked == 0) {
            gl.deleteProgram(prog);
            self.failed = true;
            return false;
        }
        self.program = prog;
        self.u_time = gl.getUniformLocation(prog, "u_time");
        self.u_res = gl.getUniformLocation(prog, "u_res");
        self.u_steps = gl.getUniformLocation(prog, "u_steps");

        gl.genVertexArrays(1, &self.vao);
        gl.genTextures(1, &self.tex);
        gl.bindTexture(gl.TEXTURE_2D, self.tex);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, self.width, self.height, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
        gl.bindTexture(gl.TEXTURE_2D, 0);

        gl.genFramebuffers(1, &self.fbo);
        gl.bindFramebuffer(gl.FRAMEBUFFER, self.fbo);
        gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, self.tex, 0);
        const status = gl.checkFramebufferStatus(gl.FRAMEBUFFER);
        gl.bindFramebuffer(gl.FRAMEBUFFER, 0);

        if (status != gl.FRAMEBUFFER_COMPLETE) {
            self.deinit();
            self.failed = true;
            return false;
        }

        self.ready = true;
        return true;
    }

    /// 渲染一帧离屏着色器压力画面（自动恢复默认帧缓冲，绝不干扰主 UI 渲染）
    pub fn renderFrame(self: *GpuStressShader, elapsed_s: f64) void {
        if (!self.ready) return;
        gl.bindFramebuffer(gl.FRAMEBUFFER, self.fbo);
        gl.viewport(0, 0, self.width, self.height);
        gl.useProgram(self.program);
        gl.uniform1f(self.u_time, @floatCast(@mod(elapsed_s, 10000.0)));
        gl.uniform2f(self.u_res, @floatFromInt(self.width), @floatFromInt(self.height));
        gl.uniform1i(self.u_steps, self.steps);
        gl.bindVertexArray(self.vao);
        gl.drawArrays(gl.TRIANGLES, 0, 3);
        gl.bindVertexArray(0);
        gl.useProgram(0);
        gl.bindFramebuffer(gl.FRAMEBUFFER, 0);
    }

    pub fn textureId(self: *const GpuStressShader) u32 {
        return if (self.ready) self.tex else 0;
    }

    /// 立即释放全部 GPU / 显存资源，平时保持零占用
    pub fn deinit(self: *GpuStressShader) void {
        if (self.fbo != 0) {
            gl.deleteFramebuffers(1, &self.fbo);
            self.fbo = 0;
        }
        if (self.tex != 0) {
            gl.deleteTextures(1, &self.tex);
            self.tex = 0;
        }
        if (self.vao != 0) {
            gl.deleteVertexArrays(1, &self.vao);
            self.vao = 0;
        }
        if (self.program != 0) {
            gl.deleteProgram(self.program);
            self.program = 0;
        }
        self.ready = false;
        self.intensity = 255;
    }
};

fn compileShader(kind: gl.Enum, src: [:0]const u8) ?u32 {
    const sh = gl.createShader(kind);
    if (sh == 0) return null;
    const ptrs = [_][*c]const gl.Char{src.ptr};
    gl.shaderSource(sh, 1, &ptrs, null);
    gl.compileShader(sh);
    var ok: i32 = 0;
    gl.getShaderiv(sh, gl.COMPILE_STATUS, &ok);
    if (ok == 0) {
        gl.deleteShader(sh);
        return null;
    }
    return sh;
}
