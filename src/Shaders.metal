#include <metal_stdlib>
using namespace metal;

constant float PI = 3.14159265;

// ---- Swift 側の構造体と一致させる ----
struct Globals {
    float4x4 viewProj;   // ワールド(mm) → クリップ
    float4 light;        // xyz: 光の来る方向, w: 強さ
    float4 misc;         // x: px/mm, y: 時間, z: 種, w: -
    float4 vp;           // 描画範囲 x,y: 原点(mm) z,w: 大きさ(mm)
    float4 shadow;       // x: 影の濃さ, y: 高さによる減衰(mm), z: 接地AO, w: 毛のふくらみ
    float4 ell[4];       // 胴の下の柔らかい影（楕円）: (cx,cy,rx,ry),(角度,高さ,濃さ,0) ×2
    float4 feet[10];     // 足先の接地影: (x,y,接地,半径)
};

struct PN { packed_float3 p; packed_float3 n; };
struct BlobInst { float4x4 model; float4 nm0; float4 nm1; float4 nm2; float4 info; float4 ext; };
// info: x=部位, y=毛の長さ, z=毛の間隔, w=乱数種   ext: xyz=半径(模様の正規化用), w=予備
struct CapInst { float4 a; float4 b; float4 side; float4 info; };
// a: 始点+半径, b: 終点+半径, side: 向きの基準+部位, info: x=節番号, y=脚番号, z=毛の長さ, w=乱数種
struct RibV { packed_float3 p; float alpha; float t; float kind; };

struct VOut {
    float4 pos [[position]];
    float3 wpos;
    float3 wn;
    float3 opos;
    float3 hdir;
    float4 info;     // 部位, 節, 脚, 種
    float4 ext;
    float shell;
    float hairLen;
};

struct ShOut { float4 pos [[position]]; float h; };

// 部位番号
#define P_CARA 0
#define P_ABDO 1
#define P_CHEL 2
#define P_EYE_BIG 3
#define P_EYE 4
#define P_LEG 5
#define P_PALP 6
#define P_FANG 7
#define P_SPIN 8
#define P_HEAD 9
#define P_THORAX 10
#define P_WING 11
#define P_ANTENNA 12
#define P_CERCUS 13
#define P_MANDIBLE 14
#define P_MEMBRANE 15
#define P_PETIOLE 16
#define P_BELLY 17
#define P_CEYE 18
#define P_SKIN 19
#define P_JAW 20
#define P_TOOTH 21
#define P_CLAW 22
#define P_REPTEYE 23
#define P_HULL 24
#define P_TREAD 25
#define P_TURRET 26
#define P_BARREL 27
#define P_METAL 28
#define P_PROPBLUR 29
#define P_PLASTIC 30
#define P_LED 31
#define P_LENS 32
#define P_PAPER 33
#define P_SAUCER 34
#define P_GLASS 35
#define P_ALIEN 36
#define P_RIMLIGHT 37
#define P_BEAM 38
#define P_GLOW 39
#define P_FLASH 40

// ---------------- ノイズ ----------------
float hash13(float3 p3) { p3 = fract(p3 * 0.1031); p3 += dot(p3, p3.zyx + 31.32); return fract((p3.x + p3.y) * p3.z); }
float3 hash33(float3 p3) {
    p3 = fract(p3 * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yxz + 33.33);
    return fract((p3.xxy + p3.yxx) * p3.zyx);
}
float hash12(float2 p) { float3 p3 = fract(float3(p.xyx) * 0.1031); p3 += dot(p3, p3.yzx + 33.33); return fract((p3.x + p3.y) * p3.z); }
float2 hash22(float2 p) { float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973)); p3 += dot(p3, p3.yzx + 33.33); return fract((p3.xx + p3.yz) * p3.zy); }

float vnoise3(float3 p) {
    float3 i = floor(p); float3 f = fract(p); f = f * f * (3.0 - 2.0 * f);
    float a = hash13(i), b = hash13(i + float3(1,0,0)), c = hash13(i + float3(0,1,0)), d = hash13(i + float3(1,1,0));
    float e = hash13(i + float3(0,0,1)), g = hash13(i + float3(1,0,1)), h = hash13(i + float3(0,1,1)), k = hash13(i + float3(1,1,1));
    return mix(mix(mix(a, b, f.x), mix(c, d, f.x), f.y), mix(mix(e, g, f.x), mix(h, k, f.x), f.y), f.z);
}
float fbm3(float3 p) {
    float s = 0.0, a = 0.5;
    for (int k = 0; k < 4; k++) { s += a * vnoise3(p); p = p * 2.03 + 1.7; a *= 0.5; }
    return s;
}
float gauss(float x, float w) { return exp(-(x * x) / (w * w)); }
float disc(float2 p, float2 c, float r, float soft) { return 1.0 - smoothstep(r - soft, r + soft, length(p - c)); }

// ---------------- 材質 ----------------
struct Mat {
    float3 alb;      // 表皮の色
    float rough;
    float spec;
    float3 hair;     // 毛の色
    float hairDen;   // 毛の密度 0..1
    float sss;       // 回り込み
};

// アダンソンハエトリ（オス）: ほぼ黒。白は主に「毛」でできている
Mat hasCarapace(float3 p, float4 ext) {
    float3 q = p / ext.xyz;
    Mat m;
    float n = fbm3(p * 7.0);
    float3 base = float3(0.014, 0.011, 0.0095) * (0.75 + 0.5 * n);
    float eyeField = smoothstep(-0.18, 0.05, q.x) * smoothstep(-0.2, 0.25, q.z);
    base = mix(base, float3(0.020, 0.009, 0.006), eyeField * 0.5);   // 眼域はわずかに赤錆色
    // 眼域を後ろと横から囲む白い U 字（前が開く）
    float wob = 0.05 * (fbm3(p * 5.0) - 0.5);
    float back = gauss(q.x + 0.20 - 0.12 * q.y * q.y + wob, 0.075) * smoothstep(0.98, 0.55, abs(q.y));
    float side = gauss(abs(q.y) - 0.80 + 0.06 * q.x + wob, 0.065) * smoothstep(-0.32, -0.12, q.x) * smoothstep(0.95, 0.55, q.x);
    float band = saturate(max(back, side)) * smoothstep(-0.25, 0.25, q.z);
    band *= smoothstep(0.30, 0.62, band + 0.35 * (fbm3(p * 14.0) - 0.5));
    // 胸部の放射状のすじ
    float ang = atan2(q.y, -q.x + 0.25);
    float striae = 0.5 + 0.5 * sin(ang * 14.0 + n * 3.0);
    base *= mix(1.0, 0.7 + 0.45 * striae, smoothstep(0.1, -0.5, q.x) * 0.5);
    m.alb = mix(base, float3(0.10, 0.095, 0.09), band * 0.6);
    m.hair = mix(float3(0.016, 0.0125, 0.010) * (0.7 + 0.7 * n), float3(0.80, 0.79, 0.76), band);
    m.hairDen = mix(0.5, 1.0, band) * (1.0 - eyeField * 0.8 * (1.0 - band));
    m.rough = mix(0.55, 0.33, eyeField * (1.0 - band));
    m.spec = mix(0.55, 0.75, eyeField);
    m.sss = 0.10;
    return m;
}

Mat hasAbdomen(float3 p, float4 ext) {
    float3 q = p / ext.xyz;
    Mat m;
    float n = fbm3(p * 5.0);
    float3 base = float3(0.016, 0.012, 0.0095) * (0.7 + 0.6 * n);
    // 中央のぼんやり明るい帯
    float mid = gauss(q.y, 0.30) * smoothstep(0.55, 0.0, q.x) * smoothstep(-0.95, -0.3, q.x);
    base = mix(base, float3(0.040, 0.029, 0.020), mid * (0.4 + 0.6 * n));
    float wob = 0.06 * (fbm3(p * 4.0) - 0.5);
    // 前縁の白い襟（後ろへ開く U 字）
    float collar = gauss(q.x - (0.66 - 0.30 * q.y * q.y) + wob, 0.085);
    float arms = gauss(abs(q.y) - 0.80 + wob, 0.07) * smoothstep(0.75, 0.25, q.x) * smoothstep(-0.55, -0.15, q.x);
    float u = saturate(max(collar, arms)) * smoothstep(-0.30, 0.20, q.z);
    // 後半の白斑（毛のかたまりなので輪郭はぼさぼさ）
    float2 qq = float2(q.x, abs(q.y)) + 0.05 * (float2(fbm3(p * 6.0), fbm3(p * 6.0 + 4.0)) - 0.5);
    float spots = max(disc(qq, float2(-0.38, 0.30), 0.09, 0.06), 0.6 * disc(qq, float2(-0.72, 0.17), 0.05, 0.04));
    spots *= smoothstep(-0.2, 0.3, q.z);
    float white = saturate(max(u, spots));
    white *= smoothstep(0.25, 0.65, white + 0.35 * (fbm3(p * 16.0) - 0.5));
    // 心臓斑（中央の縦すじ）
    float cardiac = gauss(q.y, 0.07) * smoothstep(0.6, 0.1, q.x) * smoothstep(-0.4, 0.1, q.x);
    base = mix(base, base * 0.55, cardiac * 0.6);
    m.alb = mix(base, float3(0.09, 0.085, 0.08), white * 0.6);
    m.hair = mix(float3(0.018, 0.0135, 0.011) * (0.7 + 0.7 * n) + mid * float3(0.025, 0.018, 0.012), float3(0.82, 0.81, 0.78), white);
    m.hairDen = mix(0.8, 1.0, white);
    m.rough = 0.55;
    m.spec = 0.55;
    m.sss = 0.15;
    return m;
}

Mat hasLeg(int seg, int leg, float t, float3 o) {
    Mat m;
    float3 dark = float3(0.012, 0.009, 0.007);
    float3 mid = float3(0.030, 0.021, 0.015);
    float3 pale = float3(0.085, 0.060, 0.038);
    float3 c;
    int pair = leg / 2;
    if (seg <= 1) c = mid;
    else if (seg == 2) c = mix(mid, dark, smoothstep(0.25, 0.7, t));
    else if (seg == 3) c = mix(pale * 0.8, mid, smoothstep(0.2, 0.9, t));
    else if (seg == 4) c = mix(pale * 0.8, dark, smoothstep(0.15, 0.45, t));
    else if (seg == 5) c = mix(pale, mid, smoothstep(0.35, 0.75, t));
    else c = mix(pale * 1.1, pale * 0.7, t);
    if (pair == 0) c = mix(c, dark, 0.7);            // オスの第1脚は黒い
    if (pair >= 2 && seg >= 5) c *= 1.25;            // 後ろの脚の先はやや淡い
    float n = vnoise3(float3(o.x * 9.0, o.y * 9.0, float(leg) * 3.1));
    c *= 0.8 + 0.4 * n;
    float joint = max(smoothstep(0.06, 0.0, t), smoothstep(0.94, 1.0, t));
    c = mix(c, pale * 0.8, joint * 0.3);
    m.alb = c;
    m.hair = c * 1.2 + float3(0.006, 0.005, 0.004);
    m.hairDen = 0.7;
    m.rough = 0.42;
    m.spec = 0.75;
    m.sss = 0.2;
    return m;
}

Mat hasPalp(int seg, float t, float3 o) {
    Mat m;
    float3 dark = float3(0.014, 0.010, 0.008);
    float3 white = float3(0.22, 0.21, 0.20);
    float w;
    if (seg <= 2) w = smoothstep(0.55, 0.95, t) * 0.6;
    else if (seg <= 4) w = 1.0;
    else w = (seg == 5) ? smoothstep(0.9, 0.2, t) * 0.8 : 0.1;
    float n = vnoise3(float3(o.x * 10.0, o.y * 10.0, 3.0));
    m.alb = mix(dark, white, w) * (0.8 + 0.4 * n);
    m.hair = mix(float3(0.02, 0.016, 0.013), float3(0.86, 0.85, 0.82), w);
    m.hairDen = mix(0.6, 1.0, w);
    m.rough = 0.5;
    m.spec = 0.5;
    m.sss = 0.3;
    return m;
}

// アシダカグモ（オス）
Mat hetCarapace(float3 p, float4 ext) {
    float3 q = p / ext.xyz;
    Mat m;
    float n = fbm3(p * 1.6);
    float3 base = float3(0.058, 0.034, 0.017) * (0.75 + 0.5 * n);
    float r = length(q.xy * float2(1.0, 1.05));
    // 中窩から放射するすじ・暗い斑
    float ang = atan2(q.y, q.x + 0.15);
    float striae = smoothstep(0.55, 1.0, 0.5 + 0.5 * sin(ang * 9.0 + n * 2.0)) * smoothstep(0.2, 0.75, r) * smoothstep(0.98, 0.8, r);
    base = mix(base, base * 0.45, striae * 0.6);
    float fovea = gauss(length(q.xy - float2(-0.12, 0.0)) , 0.06);
    base = mix(base, base * 0.3, fovea);
    // 縁取り（オスはクリーム色）と頭楯の淡い帯
    float rim = smoothstep(0.80, 0.93, r) * smoothstep(0.3, -0.2, q.z + 0.1);
    float clypeus = smoothstep(0.72, 0.92, q.x) * gauss(q.y, 0.75);
    float cream = saturate(max(rim, clypeus));
    float edge = smoothstep(0.95, 1.0, r);
    // 眼の後ろの明るい区画
    float behindEyes = gauss(q.x - 0.45, 0.16) * gauss(q.y, 0.35) * 0.6;
    base = mix(base, float3(0.09, 0.06, 0.032), behindEyes);
    m.alb = mix(base, float3(0.22, 0.17, 0.10), cream);
    m.alb = mix(m.alb, float3(0.05, 0.03, 0.02), edge * 0.6);
    m.hair = m.alb * 1.05 + float3(0.008, 0.006, 0.004);
    m.hairDen = 0.55;
    m.rough = 0.45;
    m.spec = 0.6;
    m.sss = 0.2;
    return m;
}

Mat hetAbdomen(float3 p, float4 ext) {
    float3 q = p / ext.xyz;
    Mat m;
    float n = fbm3(p * 0.9);
    float n2 = fbm3(p * 3.5);
    float3 base = float3(0.056, 0.034, 0.017) * (0.7 + 0.6 * n);
    // まだら模様
    float mott = smoothstep(0.45, 0.65, n2);
    base = mix(base, base * 0.55, mott * 0.7);
    // オス：中央の暗い縦すじ
    float stripe = gauss(q.y, 0.16) * smoothstep(0.85, 0.2, q.x) * smoothstep(-0.95, -0.4, q.x);
    base = mix(base, float3(0.05, 0.03, 0.018), stripe * 0.75);
    // 一対の黒点と細かい斑点
    float2 qq = float2(q.x, abs(q.y));
    float spots = disc(qq, float2(-0.1, 0.28), 0.06, 0.03) + disc(qq, float2(-0.45, 0.22), 0.05, 0.03);
    float speck = smoothstep(0.82, 0.9, vnoise3(p * 6.0));
    base = mix(base, float3(0.03, 0.02, 0.012), saturate(spots + speck * 0.5));
    m.alb = base;
    m.hair = base * 1.15 + float3(0.012, 0.009, 0.006);
    m.hairDen = 0.7;
    m.rough = 0.5;
    m.spec = 0.6;
    m.sss = 0.25;
    return m;
}

Mat hetLeg(int seg, int leg, float t, float3 o, float seed) {
    Mat m;
    float3 tan = float3(0.068, 0.043, 0.022);
    float n = vnoise3(float3(o.x * 2.0, o.y * 2.0, float(leg)));
    float3 c = tan * (0.8 + 0.35 * n);
    // 棘の根元の黒点
    float2 cell = float2(o.x * 0.9, o.y * 0.55);
    float2 ci = floor(cell);
    float2 f = fract(cell) - 0.5 - (hash22(ci + seed) - 0.5) * 0.6;
    float dot_ = (hash12(ci + seed * 1.3) > 0.55) ? (1.0 - smoothstep(0.10, 0.17, length(f))) : 0.0;
    c = mix(c, float3(0.025, 0.017, 0.012), dot_ * (seg >= 2 && seg <= 5 ? 0.9 : 0.0));
    // 先端（跗節・蹠節の先）は毛房で暗い
    if (seg == 6) c = mix(c, float3(0.06, 0.045, 0.035), smoothstep(0.2, 1.0, t));
    if (seg == 5) c = mix(c, float3(0.10, 0.07, 0.045), smoothstep(0.6, 1.0, t) * 0.6);
    float joint = max(smoothstep(0.05, 0.0, t), smoothstep(0.95, 1.0, t));
    c = mix(c, c * 0.55, joint * 0.5);
    m.alb = c;
    m.hair = c * 1.1 + float3(0.01, 0.008, 0.005);
    m.hairDen = 0.55;
    m.rough = 0.42;
    m.spec = 0.65;
    m.sss = 0.3;
    return m;
}

// ジョロウグモ（メス）
Mat joroCarapace(float3 p, float4 ext) {
    float3 q = p / ext.xyz;
    Mat m;
    float n = fbm3(p * 2.0);
    float mid = gauss(q.y, 0.22) * smoothstep(-0.9, 0.2, q.x);
    m.alb = float3(0.012, 0.012, 0.013) * (0.7 + 0.6 * n);
    m.hair = mix(float3(0.22, 0.23, 0.25), float3(0.03, 0.03, 0.035), mid * 0.8) * (0.8 + 0.4 * n);
    m.hairDen = 0.9;
    m.rough = 0.5; m.spec = 0.6; m.sss = 0.1;
    return m;
}
Mat joroAbdomen(float3 p, float4 ext) {
    float3 q = p / ext.xyz;
    Mat m;
    float n = fbm3(p * 0.8);
    float wob = 0.06 * (fbm3(p * 0.7) - 0.5);
    float3 yellow = float3(0.50, 0.36, 0.022) * (0.88 + 0.24 * n);
    float3 navy = float3(0.012, 0.024, 0.032);
    // 背中：黄色地に細い波打つ青黒の横縞
    float x = q.x * 2.1 + 0.10 * sin(q.y * 5.0) + wob;
    float stripe = smoothstep(0.030, 0.065, abs(fract(x) - 0.5) - 0.40);
    float dorsal = smoothstep(0.80, 0.62, abs(q.y)) * smoothstep(-0.35, 0.10, q.z);
    float3 c = mix(yellow, navy, stripe * 0.85);
    // 脇腹：青緑がかった黒、細い黄色の縦すじ1本
    float lat = smoothstep(0.05, 0.02, abs(q.z + 0.05) - 0.03);
    float3 side = mix(float3(0.016, 0.034, 0.040), yellow * 0.7, lat * 0.7);
    c = mix(side, c, dorsal);
    // 後ろ下の赤い斑
    float red = smoothstep(-0.65, -0.85, q.x) * smoothstep(0.1, -0.3, q.z);
    c = mix(c, float3(0.42, 0.035, 0.012), red);
    m.alb = c;
    m.hair = c * 1.1;
    m.hairDen = 0.12;
    m.rough = 0.30; m.spec = 0.9; m.sss = 0.25;
    return m;
}
Mat joroLeg(int seg, float t, float3 o) {
    Mat m;
    float3 black = float3(0.010, 0.009, 0.008);
    float3 yellow = float3(0.42, 0.30, 0.02);
    float ring = 0.0;
    if (seg == 2) ring = smoothstep(0.30, 0.22, t);
    if (seg == 4) ring = smoothstep(0.28, 0.20, t);
    if (seg == 5) ring = smoothstep(0.20, 0.13, t);
    m.alb = mix(black, yellow, ring) * (0.85 + 0.3 * vnoise3(float3(o.x * 3.0, o.y * 3.0, 1.0)));
    m.hair = m.alb * 1.2;
    m.hairDen = 0.4;
    m.rough = 0.35; m.spec = 0.85; m.sss = 0.2;
    return m;
}

// タランチュラ（メキシカンレッドニー）
Mat taraCarapace(float3 p, float4 ext) {
    float3 q = p / ext.xyz;
    Mat m;
    float n = fbm3(p * 0.6);
    float r = length(q.xy);
    float margin = smoothstep(0.74, 0.88, r);
    float ang = atan2(q.y, q.x);
    float star = smoothstep(0.6, 1.0, 0.5 + 0.5 * sin(ang * 8.0)) * smoothstep(0.15, 0.6, r) * (1.0 - margin);
    float3 base = float3(0.010, 0.0085, 0.007) * (0.8 + 0.4 * n);
    m.alb = mix(base, float3(0.30, 0.12, 0.030), margin);
    m.hair = mix(float3(0.016, 0.013, 0.011), float3(0.40, 0.17, 0.045), margin);
    m.hair = mix(m.hair, float3(0.07, 0.04, 0.025), star * 0.6);
    m.hairDen = 0.95;
    m.rough = 0.6; m.spec = 0.5; m.sss = 0.1;
    return m;
}
Mat taraAbdomen(float3 p, float4 ext) {
    Mat m;
    float n = fbm3(p * 0.35);
    float red = smoothstep(0.55, 0.75, n);
    m.alb = float3(0.008, 0.007, 0.006);
    m.hair = mix(float3(0.013, 0.010, 0.008), float3(0.13, 0.040, 0.012), red * 0.6);
    m.hairDen = 1.0;
    m.rough = 0.65; m.spec = 0.4; m.sss = 0.1;
    return m;
}
Mat taraLeg(int seg, float t, float3 o) {
    Mat m;
    float3 black = float3(0.010, 0.0085, 0.007);
    float3 orange = float3(0.46, 0.085, 0.012);
    float3 cream = float3(0.34, 0.29, 0.21);
    float3 c = black;
    if (seg == 3) c = mix(orange, black, smoothstep(0.82, 0.95, t) + smoothstep(0.42, 0.50, t) * smoothstep(0.58, 0.50, t));
    if (seg == 4) c = mix(orange, black, smoothstep(0.28, 0.40, t));
    if ((seg == 4 || seg == 5) && t > 0.93) c = cream;
    if (seg == 2) c = mix(black, cream * 0.5, smoothstep(0.95, 1.0, t));
    m.alb = c * 0.8;
    m.hair = c * (0.9 + 0.3 * vnoise3(float3(o.x * 2.0, o.y * 2.0, 3.0)));
    m.hairDen = 1.0;
    m.rough = 0.6; m.spec = 0.5; m.sss = 0.1;
    return m;
}

Mat spiderMat(int species, int part, float3 o, float4 ext, float4 info, float seed) {
    Mat m;
    m.alb = float3(0.03); m.rough = 0.4; m.spec = 0.8; m.hair = float3(0.05); m.hairDen = 0.0; m.sss = 0.15;
    int seg = int(info.y);
    if (part == P_CARA) {
        if (species == 0) return hasCarapace(o, ext);
        if (species == 1) return hetCarapace(o, ext);
        if (species == 2) return joroCarapace(o, ext);
        return taraCarapace(o, ext);
    }
    if (part == P_ABDO) {
        if (species == 0) return hasAbdomen(o, ext);
        if (species == 1) return hetAbdomen(o, ext);
        if (species == 2) return joroAbdomen(o, ext);
        return taraAbdomen(o, ext);
    }
    if (part == P_LEG) {
        if (species == 0) return hasLeg(seg, int(info.z), o.z, o);
        if (species == 1) return hetLeg(seg, int(info.z), o.z, o, seed);
        if (species == 2) return joroLeg(seg, o.z, o);
        return taraLeg(seg, o.z, o);
    }
    if (part == P_PALP) {
        if (species == 0) return hasPalp(seg, o.z, o);
        if (species == 2) return joroLeg(seg, o.z, o);
        if (species == 3) return taraLeg(seg, o.z, o);
        Mat h = hetLeg(seg, 9, o.z, o, seed);
        if (seg >= 5) h.alb *= 0.55;
        return h;
    }
    if (part == P_CHEL) {
        float n = fbm3(o * 3.0);
        float3 c = species == 0 ? float3(0.030, 0.017, 0.011) : (species == 1 ? float3(0.07, 0.030, 0.014) : float3(0.012, 0.010, 0.009));
        m.alb = c * (0.8 + 0.4 * n);
        m.rough = 0.24; m.spec = 1.0; m.hair = species == 3 ? float3(0.015) : m.alb * 1.5; m.hairDen = species == 3 ? 0.9 : 0.3;
        return m;
    }
    if (part == P_FANG) { m.alb = float3(0.06, 0.020, 0.010); m.rough = 0.15; m.spec = 1.0; return m; }
    if (part == P_EYE_BIG || part == P_EYE) { m.alb = float3(0.004, 0.0035, 0.003); m.rough = 0.045; m.spec = 1.4; m.sss = 0.0; return m; }
    if (part == P_SPIN) { m.alb = species == 1 ? float3(0.16, 0.10, 0.05) : float3(0.03, 0.022, 0.016); m.rough = 0.5; return m; }
    return m;
}

// ---- 昆虫 ----
Mat glossy(float3 c, float rough, float spec) {
    Mat m; m.alb = c; m.rough = rough; m.spec = spec; m.hair = c; m.hairDen = 0.0; m.sss = 0.12; return m;
}

Mat cockroachMat(int part, float3 o, float4 ext, float4 info, float seed) {
    float n = fbm3(o * 1.3);
    if (part == P_THORAX) {
        float3 q = o / ext.xyz;
        float rim = smoothstep(0.82, 0.97, length(q.xy));
        float3 c = mix(float3(0.010, 0.0050, 0.0028), float3(0.045, 0.018, 0.007), rim * 0.8) * (0.85 + 0.3 * n);
        Mat m = glossy(c, 0.16 + 0.06 * vnoise3(o * 9.0), 1.25);
        return m;
    }
    if (part == P_WING) {
        // 前翅：縦に走る翅脈のすじ、やや透ける縁
        float veins = vnoise3(float3(o.x * 0.9, o.y * 9.0, o.z * 9.0));
        float fine = vnoise3(float3(o.x * 2.0 + 3.0, o.y * 26.0, o.z * 26.0));
        float3 c = float3(0.017, 0.0068, 0.0034) * (0.7 + 0.45 * veins + 0.25 * fine) * (0.85 + 0.3 * n);
        Mat m = glossy(c, 0.20 + 0.08 * fine, 1.1);
        return m;
    }
    if (part == P_HEAD) {
        float3 q = o / ext.xyz;
        float3 c = mix(float3(0.011, 0.005, 0.003), float3(0.05, 0.022, 0.010), smoothstep(0.3, 0.9, q.x) * smoothstep(0.0, -0.6, q.z));
        return glossy(c * (0.85 + 0.3 * n), 0.22, 1.1);
    }
    if (part == P_BELLY) {
        float band = smoothstep(0.80, 0.95, fract(o.x / 1.6));
        return glossy(mix(float3(0.030, 0.012, 0.006), float3(0.012, 0.005, 0.003), band), 0.3, 0.9);
    }
    if (part == P_LEG) {
        int seg = int(info.y);
        float t = o.z;
        float3 c = float3(0.030, 0.012, 0.0055);
        if (seg >= 5) c = float3(0.045, 0.020, 0.009);
        if (seg <= 1) c = float3(0.022, 0.009, 0.0045);
        c *= 0.85 + 0.3 * vnoise3(float3(o.x * 3.0, o.y * 3.0, seed));
        float joint = max(smoothstep(0.06, 0.0, t), smoothstep(0.94, 1.0, t));
        c = mix(c, c * 1.6, joint * 0.4);
        Mat m = glossy(c, 0.28, 1.0);
        m.hair = c * 1.4; m.hairDen = 0.25;
        return m;
    }
    if (part == P_ANTENNA) {
        float t = o.z;
        float ring = smoothstep(0.85, 1.0, t);
        return glossy(float3(0.026, 0.012, 0.0065) * (1.0 - 0.3 * ring), 0.35, 0.8);
    }
    if (part == P_CERCUS || part == P_PALP) return glossy(float3(0.045, 0.020, 0.010), 0.4, 0.7);
    if (part == P_CEYE) {
        float facet = pow(vnoise3(o * 38.0), 6.0);
        return glossy(float3(0.004, 0.003, 0.003) + facet * 0.02, 0.12, 1.2);
    }
    return glossy(float3(0.02, 0.009, 0.005), 0.3, 0.9);
}

Mat antMat(int part, float3 o, float4 ext, float4 info, float seed) {
    float n = fbm3(o * 4.0);
    float pits = vnoise3(o * 28.0);
    float3 black = float3(0.0085, 0.0075, 0.007) * (0.85 + 0.3 * n);
    if (part == P_HEAD || part == P_THORAX || part == P_PETIOLE) {
        Mat m = glossy(black, 0.36 + 0.12 * pits, 0.75);
        m.hair = float3(0.016, 0.014, 0.012); m.hairDen = 0.18;
        return m;
    }
    if (part == P_BELLY) {
        // ガスター：節の縁がわずかに透けた茶色、金灰色の微毛
        float3 q = o / ext.xyz;
        float rims = 0.0;
        for (int k = 0; k < 4; k++) {
            float x0 = 0.62 - 0.40 * float(k);
            rims = max(rims, gauss(q.x - x0 + 0.08 * q.y * q.y, 0.035));
        }
        float3 c = mix(black, float3(0.05, 0.032, 0.018), rims * smoothstep(-0.3, 0.2, q.z));
        Mat m = glossy(c, 0.30, 0.8);
        m.hair = float3(0.030, 0.026, 0.019); m.hairDen = 0.32;
        return m;
    }
    if (part == P_LEG) {
        int seg = int(info.y);
        float3 c = seg >= 5 ? float3(0.040, 0.026, 0.016) : float3(0.012, 0.0095, 0.008);
        Mat m = glossy(c, 0.35, 0.8);
        m.hair = float3(0.022, 0.018, 0.014); m.hairDen = 0.2;
        return m;
    }
    if (part == P_ANTENNA) return glossy(info.z < 0.5 && o.z < 0.0 ? black : float3(0.020, 0.014, 0.010), 0.4, 0.6);
    if (part == P_MANDIBLE) {
        float tip = smoothstep(0.5, 1.0, o.z) * (int(info.y) == 1 ? 1.0 : 0.0);
        return glossy(mix(float3(0.032, 0.012, 0.006), float3(0.012, 0.005, 0.003), tip), 0.2, 1.1);
    }
    if (part == P_CEYE) {
        float facet = pow(vnoise3(o * 34.0), 6.0);
        return glossy(float3(0.018, 0.017, 0.016) + facet * 0.03, 0.15, 1.1);
    }
    return glossy(float3(0.03, 0.02, 0.012), 0.4, 0.6);
}

Mat ladybugMat(int part, float3 o, float4 ext, float4 info, float seed) {
    float n = fbm3(o * 3.0);
    if (part == P_WING) {
        // 鞘翅：朱赤に黒紋（左右で7つ＝それぞれ3つ＋前の合わせ目に1つ）
        float2 q = float2(o.x, abs(o.y));
        float2 w = 0.12 * (float2(fbm3(o * 2.5), fbm3(o * 2.5 + 7.0)) - 0.5);
        float spots = max(max(disc(q + w, float2(1.10, 1.45), 0.62, 0.06), disc(q + w, float2(-0.35, 2.05), 0.52, 0.06)),
                          max(disc(q + w, float2(-1.45, 1.05), 0.55, 0.06), disc(q + w, float2(2.35, 0.0), 0.55, 0.06)));
        float3 red = float3(0.62, 0.040, 0.007) * (0.92 + 0.16 * n);
        float3 c = mix(red, float3(0.006, 0.005, 0.005), spots);
        // 縁のわずかな淡い張り出し
        float rim = smoothstep(0.25, 0.05, o.z + 0.0) * 0.3;
        c = mix(c, c * 1.2 + 0.02, rim * (1.0 - spots));
        Mat m = glossy(c, 0.07 + 0.03 * vnoise3(o * 14.0), 1.5);
        m.sss = mix(0.35, 0.05, spots);
        return m;
    }
    if (part == P_THORAX) {
        float3 q = o / ext.xyz;
        float patch_ = smoothstep(0.62, 0.72, abs(q.y)) * smoothstep(-0.1, 0.25, q.x) * smoothstep(1.0, 0.86, length(q.xy * float2(1.0, 0.97)));
        float3 c = mix(float3(0.006, 0.0055, 0.005), float3(0.72, 0.70, 0.64), patch_);
        return glossy(c, 0.12, 1.3);
    }
    if (part == P_HEAD) {
        float3 q = o / ext.xyz;
        float2 qq = float2(q.x, abs(q.y));
        float spot = disc(qq, float2(0.15, 0.55), 0.2, 0.06) * smoothstep(-0.2, 0.3, q.z);
        return glossy(mix(float3(0.006, 0.0055, 0.005), float3(0.7, 0.68, 0.62), spot), 0.15, 1.2);
    }
    if (part == P_MEMBRANE) return glossy(float3(0.25, 0.20, 0.16), 0.3, 0.5);
    if (part == P_CEYE) return glossy(float3(0.012, 0.010, 0.009), 0.1, 1.2);
    if (part == P_ANTENNA) return glossy(float3(0.025, 0.018, 0.012), 0.35, 0.7);
    return glossy(float3(0.007, 0.006, 0.0055), 0.18, 1.1);
}

// ---- 恐竜・乗り物・もの ----
// ボロノイ（鱗）：x = 最寄りの点までの距離, y = 2番目との差（縁ほど 0）, z = セルの乱数
float3 voronoi3(float3 p) {
    float3 i = floor(p);
    float d1 = 9.0, d2 = 9.0, h = 0.0;
    for (int z = -1; z <= 1; z++) for (int y = -1; y <= 1; y++) for (int x = -1; x <= 1; x++) {
        float3 c = i + float3(x, y, z);
        float3 fp = c + 0.15 + 0.7 * hash33(c);
        float d = length(p - fp);
        if (d < d1) { d2 = d1; d1 = d; h = hash13(c + 3.1); } else if (d < d2) { d2 = d; }
    }
    return float3(d1, d2 - d1, h);
}

float dinoCells(float3 o, float4 ext, float4 info, int part) {
    bool isCap = info.z > 19.5;
    float3 pp = isCap ? float3(o.x, o.y, info.z * 3.0) : o;
    float size = part == P_JAW || (!isCap && ext.x < 6.5) ? 0.32 : 0.48;
    if (isCap && (info.z > 21.5)) size = 0.30;
    float3 v = voronoi3(pp / size);
    return v.y;
}

Mat dinoMat(int part, float3 o, float4 ext, float4 info, float seed) {
    Mat m;
    m.hair = float3(0); m.hairDen = 0; m.sss = 0.15;
    if (part == P_TOOTH) { m.alb = float3(0.50, 0.45, 0.33); m.rough = 0.25; m.spec = 1.0; return m; }
    if (part == P_CLAW) { m.alb = float3(0.025, 0.020, 0.016); m.rough = 0.25; m.spec = 1.0; return m; }
    if (part == P_REPTEYE) {
        float pupil = smoothstep(0.16, 0.08, abs(o.x)) * smoothstep(-0.2, 0.3, o.z);
        m.alb = mix(float3(0.42, 0.25, 0.04), float3(0.004), pupil);
        m.rough = 0.04; m.spec = 1.4; m.sss = 0.0;
        return m;
    }
    bool isCap = info.z > 19.5;
    float dorsal;
    float along;
    if (isCap) {
        float phi = o.y / max(ext.w, 1e-3);
        dorsal = smoothstep(-0.3, 0.8, cos(phi));
        along = o.x + info.z * 11.0;
    } else {
        float3 q = o / ext.xyz;
        dorsal = smoothstep(-0.45, 0.55, q.z);
        along = o.x;
    }
    float n = fbm3(o * 0.35 + info.z);
    float3 back = float3(0.026, 0.024, 0.015) * (0.8 + 0.4 * n);
    float3 flank = float3(0.095, 0.075, 0.042) * (0.85 + 0.3 * n);
    float3 belly = float3(0.19, 0.16, 0.105);
    float3 c = mix(belly, flank, smoothstep(-0.9, -0.2, (dorsal - 0.5) * 2.0));
    c = mix(c, back, smoothstep(0.35, 0.85, dorsal));
    // 背中の暗い横じま
    float stripe = smoothstep(0.55, 0.85, 0.5 + 0.5 * sin(along * 0.75 + n * 3.0)) * smoothstep(0.4, 0.9, dorsal);
    c = mix(c, c * 0.45, stripe * 0.7);
    if (part == P_JAW) c = mix(float3(0.16, 0.13, 0.085), c, 0.5);
    float cell = dinoCells(o, ext, info, part);
    float groove = 1.0 - smoothstep(0.0, 0.12, cell);
    c *= mix(1.08, 0.55, groove);
    m.alb = c;
    m.rough = mix(0.45, 0.75, groove);
    m.spec = 0.65;
    return m;
}

Mat tankMat(int part, float3 o, float4 ext, float4 info, float seed) {
    Mat m;
    m.hair = float3(0); m.hairDen = 0; m.sss = 0.05;
    if (part == P_METAL) { m.alb = float3(0.024, 0.024, 0.026); m.rough = 0.42; m.spec = 1.1; return m; }
    if (part == P_LENS) { m.alb = float3(0.06, 0.06, 0.055); m.rough = 0.06; m.spec = 1.4; return m; }
    if (part == P_TREAD) {
        float scroll = ext.w;
        float link = fract((o.x - scroll) / 1.05);
        float groove = smoothstep(0.0, 0.08, link) * smoothstep(1.0, 0.86, link);
        float pad = smoothstep(0.35, 0.25, abs(o.y) / 1.95);
        float3 c = mix(float3(0.012, 0.011, 0.010), float3(0.036, 0.033, 0.029), groove);
        c = mix(c, float3(0.06, 0.05, 0.04), pad * 0.25 * groove);
        c *= 0.85 + 0.3 * vnoise3(o * 2.0);
        m.alb = c; m.rough = 0.6; m.spec = 0.9;
        return m;
    }
    // 迷彩（緑・茶・黒）＋ 下の方の土ぼこり
    float3 w = o * 0.22 + seed * 3.0;
    float n1 = fbm3(w), n2 = fbm3(w + 7.3), n3 = fbm3(w * 1.6 + 2.1);
    float3 c = float3(0.046, 0.052, 0.026);
    c = mix(c, float3(0.058, 0.040, 0.024), smoothstep(0.52, 0.56, n1));
    c = mix(c, float3(0.012, 0.012, 0.010), smoothstep(0.60, 0.63, n2));
    c = mix(c, float3(0.026, 0.038, 0.020), smoothstep(0.55, 0.58, n3) * 0.8);
    float dust = smoothstep(-0.2, -0.95, o.z / max(ext.z, 0.1)) * 0.6 + 0.25 * smoothstep(0.55, 0.8, vnoise3(o * 1.3));
    c = mix(c, float3(0.11, 0.095, 0.07), dust * 0.55);
    if (part == P_HULL && ext.x > 13.0) {
        // 機関室のグリル
        float grill = step(o.x, -5.5) * step(-11.5, o.x) * step(abs(o.y), 5.0);
        float slat = smoothstep(0.35, 0.5, abs(fract(o.y * 1.4) - 0.5));
        c = mix(c, c * mix(1.0, 0.25, slat), grill);
        float hatch = smoothstep(1.3, 1.2, length(o.xy - float2(8.5, 3.6))) - smoothstep(1.1, 1.0, length(o.xy - float2(8.5, 3.6)));
        c *= 1.0 - hatch * 0.6;
    }
    if (part == P_BARREL) c = mix(c, float3(0.012, 0.011, 0.010), smoothstep(0.85, 1.0, o.z));
    m.alb = c;
    m.rough = 0.62;
    m.spec = 0.7;
    return m;
}

Mat droneMat(int part, float3 o, float4 ext, float4 info, float seed) {
    Mat m;
    m.hair = float3(0); m.hairDen = 0; m.sss = 0.1;
    if (part == P_METAL) { m.alb = float3(0.018, 0.018, 0.02); m.rough = 0.3; m.spec = 1.2; return m; }
    if (part == P_LENS) { m.alb = float3(0.004, 0.004, 0.006); m.rough = 0.04; m.spec = 1.6; return m; }
    if (part == P_LED) { m.alb = float3(0.2); m.rough = 0.2; m.spec = 1.0; return m; }
    float3 c = seed > 8.5 ? float3(0.03, 0.03, 0.032) : float3(0.24, 0.245, 0.25);
    // パネルの継ぎ目
    if (part == P_PLASTIC && info.z < 0.5 && seed < 1.5) {
        float seam = 1.0 - smoothstep(0.02, 0.06, abs(o.x - 3.2)) * step(0.0, o.z);
        float seam2 = 1.0 - smoothstep(0.02, 0.06, abs(abs(o.y) - 2.3)) * step(0.5, o.z);
        c *= min(seam, seam2) * 0.5 + 0.5;
    }
    c *= 0.92 + 0.12 * vnoise3(o * 6.0);
    m.alb = c; m.rough = 0.5; m.spec = 0.8;
    return m;
}

Mat paperMat(int part, float3 o) {
    Mat m;
    m.hair = float3(0); m.hairDen = 0;
    float fiber = vnoise3(float3(o.x * 9.0, o.y * 2.5, 0.0)) * 0.5 + vnoise3(o * 22.0) * 0.5;
    float3 c = float3(0.62, 0.61, 0.575) * (0.95 + 0.07 * fiber);
    // ノートの罫線（紙を斜めに折ったので斜めに走る）
    float2 dir = normalize(float2(0.42, 1.0));
    float l = abs(fract(dot(o.xy, dir) / 2.2) - 0.5);
    float line = smoothstep(0.05, 0.02, l);
    c = mix(c, float3(0.32, 0.45, 0.72), line * 0.35);
    float margin = smoothstep(0.08, 0.02, abs(dot(o.xy, float2(dir.y, -dir.x)) - 6.0));
    c = mix(c, float3(0.70, 0.25, 0.25), margin * 0.35);
    m.alb = c; m.rough = 0.85; m.spec = 0.15; m.sss = 0.25;
    return m;
}

Mat ufoMat(int part, float3 o, float4 ext, float4 info, float seed) {
    Mat m;
    m.hair = float3(0); m.hairDen = 0; m.sss = 0.05;
    if (part == P_ALIEN) { m.alb = float3(0.10, 0.26, 0.07) * (0.85 + 0.3 * vnoise3(o * 3.0)); m.rough = 0.35; m.spec = 0.8; m.sss = 0.6; return m; }
    if (part == P_LENS) { m.alb = float3(0.003); m.rough = 0.05; m.spec = 1.5; return m; }
    if (part == P_RIMLIGHT) { m.alb = float3(0.15); m.rough = 0.15; m.spec = 1.0; return m; }
    // 磨いた金属の円盤：同心円と放射状の継ぎ目
    float r = length(o.xy);
    float ang = atan2(o.y, o.x);
    float rings = 1.0 - smoothstep(0.02, 0.07, abs(fract(r / 2.4) - 0.5) - 0.44);
    float rad = 1.0 - smoothstep(0.01, 0.03, abs(fract(ang / (2.0 * PI) * 16.0) - 0.5) - 0.47) * step(6.0, r);
    float brushed = vnoise3(float3(r * 6.0, 0.0, 0.0)) * 0.5 + vnoise3(float3(r * 23.0, 1.0, 0.0)) * 0.5;
    float3 c = float3(0.13, 0.135, 0.14) * (0.88 + 0.22 * brushed);
    c *= mix(1.0, 0.40, max(rings, rad) * 0.8);
    m.alb = c; m.rough = 0.30 + 0.12 * max(rings, rad); m.spec = 1.5;
    return m;
}

float3 emission(int species, int part, float3 o, float4 ext, float4 info, float time) {
    float seed = info.w;
    if (part == P_LED) {
        if (seed < 0.5) return float3(0.6, 1.4, 0.8) * (0.7 + 0.3 * sin(time * 3.0));
        float blink = step(0.5, fract(time * 1.3)) * 1.0 + 0.15;
        return float3(2.4, 0.2, 0.15) * blink;
    }
    if (part == P_RIMLIGHT) {
        float3 col = seed < 0.5 ? float3(0.15, 1.0, 1.3) : (seed < 1.5 ? float3(1.4, 0.18, 0.9) : float3(1.5, 0.85, 0.12));
        return col * (0.4 + 4.5 * ext.w);
    }
    return float3(0.0);
}

float surfaceBump(int species, int part, float3 o, float4 ext, float4 info) {
    if (species == 7 && (part == P_SKIN || part == P_JAW)) {
        float cell = dinoCells(o, ext, info, part);
        return smoothstep(0.0, 0.18, cell) * 0.07;
    }
    if (species == 10 && part == P_PAPER) return vnoise3(o * 18.0) * 0.004;
    return 0.0;
}

Mat surfaceMat(int species, int part, float3 o, float4 ext, float4 info, float seed) {
    if (species <= 3) return spiderMat(species, part, o, ext, info, seed);
    if (species == 4) return cockroachMat(part, o, ext, info, seed);
    if (species == 5) return antMat(part, o, ext, info, seed);
    if (species == 6) return ladybugMat(part, o, ext, info, seed);
    if (species == 7) return dinoMat(part, o, ext, info, seed);
    if (species == 8) return tankMat(part, o, ext, info, seed);
    if (species == 9) return droneMat(part, o, ext, info, seed);
    if (species == 10) return paperMat(part, o);
    return ufoMat(part, o, ext, info, seed);
}

// ---------------- 照明 ----------------
float3 envLight(float3 R, float3 L) {
    // スタジオ風の環境：上空は明るく、画面（地面）側は暗い。主光源の方向に大きなソフトボックス
    float3 c = mix(float3(0.035, 0.034, 0.033), float3(0.30, 0.31, 0.33), smoothstep(-0.2, 0.9, R.z));
    // ソフトボックス（四角い反射）
    float3 Lt = normalize(cross(L, float3(0, 0, 1)) + float3(1e-4, 0, 0));
    float3 Lb = normalize(cross(Lt, L));
    float x = dot(R, Lt), y = dot(R, Lb), z = dot(R, L);
    float box = smoothstep(0.30, 0.22, abs(x)) * smoothstep(0.22, 0.15, abs(y)) * step(0.0, z);
    c += float3(3.2, 3.1, 2.95) * box;
    // 小さな補助光
    float3 L2 = normalize(float3(0.75, 0.25, 0.65));
    c += float3(0.9, 0.95, 1.05) * pow(saturate(dot(R, L2)), 90.0) * 2.0;
    return c;
}

float3 shadeSurface(Mat m, float3 N, float3 wpos, constant Globals& g, float ao) {
    float3 L = normalize(g.light.xyz);
    float3 V = float3(0, 0, 1);
    float3 H = normalize(L + V);
    float NdL = dot(N, L);
    float diff = saturate((NdL + m.sss) / (1.0 + m.sss));
    float NdH = saturate(dot(N, H));
    float a = max(m.rough * m.rough, 0.002);
    float a2 = a * a;
    float d = NdH * NdH * (a2 - 1.0) + 1.0;
    float D = a2 / (PI * d * d);
    float NdV = saturate(N.z);
    float F = 0.04 + 0.96 * pow(1.0 - saturate(dot(H, V)), 5.0);
    float G = 1.0 / (4.0 * max(NdV, 0.15) * max(saturate(NdL), 0.15));
    float3 lightCol = float3(1.0, 0.975, 0.94) * g.light.w;
    float3 spec = lightCol * (D * F * G * saturate(NdL) * m.spec);
    float3 R = reflect(-V, N);
    float Fv = 0.04 + 0.96 * pow(1.0 - NdV, 5.0);
    float3 env = envLight(R, L) * Fv * m.spec * (1.0 - 0.85 * m.rough);
    float3 amb = mix(float3(0.05, 0.048, 0.046), float3(0.34, 0.35, 0.37), saturate(N.z * 0.5 + 0.5)) * ao;
    return m.alb * (diff * lightCol + amb) + (spec + env) * ao;
}

float3 tonemap(float3 c) {
    c *= 1.05;
    float3 x = (c * (2.51 * c + 0.03)) / (c * (2.43 * c + 0.59) + 0.14);
    x = saturate(x);
    return select(1.055 * pow(x, 1.0 / 2.4) - 0.055, x * 12.92, x <= 0.0031308);
}

// 胴の下側や地面近くは暗くなる
float partAO(float3 N, float3 wpos, int part) {
    float down = saturate(-N.z);
    float ao = 1.0 - down * 0.6;
    ao *= mix(0.55, 1.0, saturate(wpos.z * 1.2));
    return ao;
}

// ---------------- 頂点シェーダ ----------------
vertex VOut vBlob(uint vid [[vertex_id]], uint iid [[instance_id]],
                  const device PN* V [[buffer(0)]],
                  const device BlobInst* I [[buffer(1)]],
                  constant Globals& g [[buffer(2)]],
                  constant float4& sh [[buffer(3)]]) {
    uint n = max(uint(sh.y), 1u);
    uint inst = iid % n;
    uint si = iid / n;
    float h = sh.x > 0.0 ? (float(si) + 1.0) / sh.x : 0.0;
    BlobInst b = I[inst];
    float3 p = float3(V[vid].p);
    float3 nn = float3(V[vid].n);
    float3x3 nm = float3x3(b.nm0.xyz, b.nm1.xyz, b.nm2.xyz);
    float3 wn = normalize(nm * nn);
    float3 wp = (b.model * float4(p, 1.0)).xyz;
    float hl = b.info.y;
    float3 back = normalize((b.model * float4(-1.0, 0.0, -0.25, 0.0)).xyz);
    float3 lean = back - wn * dot(back, wn);
    wp += wn * (h * hl * 0.75) + lean * (h * h * hl * 1.8);
    VOut o;
    o.pos = g.viewProj * float4(wp, 1.0);
    o.wpos = wp;
    o.wn = wn;
    o.opos = p;
    o.hdir = normalize(wn * 0.6 + lean + 1e-4);
    o.info = float4(b.info.x, 0, 0, b.info.w);
    o.ext = b.ext;
    o.shell = h;
    o.hairLen = hl;
    return o;
}

struct CapGeo { float3 pos; float3 nrm; float axial; float len; float3 e; };

CapGeo capsuleGeo(float3 m, CapInst c) {
    CapGeo r;
    float3 a = c.a.xyz, b = c.b.xyz;
    float r0 = c.a.w, r1 = c.b.w;
    float3 ax = b - a;
    float len = max(length(ax), 1e-4);
    float3 e = ax / len;
    float3 s = c.side.xyz;
    float3 n1 = s - e * dot(s, e);
    n1 = length(n1) > 1e-4 ? normalize(n1) : normalize(cross(e, float3(0.3, 0.2, 0.9)));
    float3 n2 = cross(e, n1);
    float phi = m.z;
    float3 rad = n1 * cos(phi) + n2 * sin(phi);
    if (m.x < 0.5) {
        float be = m.y;
        r.pos = a - e * r0 * sin(be) + rad * r0 * cos(be);
        r.nrm = -e * sin(be) + rad * cos(be);
        r.axial = -r0 * sin(be);
    } else if (m.x < 1.5) {
        float t = m.y;
        r.pos = a + ax * t + rad * mix(r0, r1, t);
        r.nrm = normalize(rad - e * (r1 - r0) / len);
        r.axial = t * len;
    } else {
        float be = m.y;
        r.pos = b + e * r1 * sin(be) + rad * r1 * cos(be);
        r.nrm = e * sin(be) + rad * cos(be);
        r.axial = len + r1 * sin(be);
    }
    r.len = len;
    r.e = e;
    return r;
}

vertex VOut vCap(uint vid [[vertex_id]], uint iid [[instance_id]],
                 const device packed_float3* M [[buffer(0)]],
                 const device CapInst* I [[buffer(1)]],
                 constant Globals& g [[buffer(2)]],
                 constant float4& sh [[buffer(3)]]) {
    uint n = max(uint(sh.y), 1u);
    uint inst = iid % n;
    uint si = iid / n;
    float h = sh.x > 0.0 ? (float(si) + 1.0) / sh.x : 0.0;
    CapInst c = I[inst];
    CapGeo G = capsuleGeo(float3(M[vid]), c);
    float hl = c.info.z;
    float3 lean = G.e - G.nrm * dot(G.e, G.nrm);
    float3 wp = G.pos + G.nrm * (h * hl * 0.8) + lean * (h * h * hl * 1.6);
    VOut o;
    o.pos = g.viewProj * float4(wp, 1.0);
    o.wpos = wp;
    o.wn = G.nrm;
    float rAvg = 0.5 * (c.a.w + c.b.w);
    o.opos = float3(G.axial, float3(M[vid]).z * rAvg, clamp(G.axial / G.len, 0.0, 1.0));
    o.hdir = normalize(G.nrm * 0.5 + lean + 1e-4);
    o.info = float4(c.side.w, c.info.x, c.info.y, c.info.w);
    o.ext = float4(c.a.w, c.b.w, G.len, rAvg);
    o.shell = h;
    o.hairLen = hl;
    return o;
}

// ---------------- 表面（不透明） ----------------
fragment float4 fSolid(VOut in [[stage_in]], constant Globals& g [[buffer(0)]], bool front [[front_facing]]) {
    int part = int(in.info.x + 0.5);
    int species = int(g.misc.z + 0.5);
    float3 N = normalize(in.wn);
    if (part == P_PAPER && N.z < 0.0) N = -N;
    float bh = surfaceBump(species, part, in.opos, in.ext, in.info);
    float2 gr = float2(dfdx(bh), -dfdy(bh)) * g.misc.x;
    N = normalize(N - float3(gr, 0.0) * 0.8);
    Mat m = surfaceMat(species, part, in.opos, in.ext, in.info, in.info.w);
    float ao = partAO(N, in.wpos, part);
    // 毛に覆われた面：毛並みに沿った細かいすじ模様（毛の色が地肌を覆う）
    if (m.hairDen > 0.01) {
        float sc = 0.045 / max(g.misc.w, 0.01);
        float streak;
        if (part == P_LEG || part == P_PALP) {
            streak = vnoise3(float3(in.opos.x * 14.0 * sc, in.opos.y * 95.0 * sc, in.info.w));
            streak = 0.6 * streak + 0.4 * vnoise3(float3(in.opos.x * 30.0 * sc, in.opos.y * 190.0 * sc, in.info.w + 3.0));
        } else {
            float3 pp = in.opos * sc;
            streak = vnoise3(float3(pp.x * 16.0, pp.y * 110.0, pp.z * 110.0));
            streak = 0.6 * streak + 0.4 * vnoise3(float3(pp.x * 34.0 + 2.0, pp.y * 230.0, pp.z * 230.0));
        }
        float cover = saturate(m.hairDen * 1.1);
        float3 hairTex = m.hair * (0.45 + 1.1 * streak);
        m.alb = mix(m.alb, hairTex, cover * 0.85);
        m.rough = mix(m.rough, 0.62 - 0.25 * streak, cover);
        m.spec *= mix(1.0, 0.35 + 0.9 * streak * streak, cover);
    }
    if (part == P_EYE_BIG) {
        // 主眼の奥にかすかな琥珀色の網膜
        float3 q = in.opos;
        float rim = smoothstep(0.55, 0.95, length(q.yz));
        m.alb += float3(0.03, 0.018, 0.006) * (1.0 - rim) * 0.6;
    }
    float3 c = shadeSurface(m, N, in.wpos, g, ao);
    c += emission(species, part, in.opos, in.ext, in.info, g.misc.y);
    return float4(tonemap(c), 1.0);
}

// ---------------- 毛（シェル法） ----------------
fragment float4 fShell(VOut in [[stage_in]], constant Globals& g [[buffer(0)]]) {
    int part = int(in.info.x + 0.5);
    int species = int(g.misc.z + 0.5);
    float pxmm = g.misc.x;
    float h = in.shell;
    Mat m = surfaceMat(species, part, in.opos, in.ext, in.info, in.info.w);
    if (m.hairDen <= 0.01) discard_fragment();
    float spacing;
    float dist;
    float rnd;
    if (part == P_LEG || part == P_PALP) {
        // 円筒状の座標（軸方向, 周方向）でセルを切る
        spacing = g.misc.w * (part == P_PALP ? 0.8 : 1.0);
        float rAvg = in.ext.w;
        float around = max(3.0, round(2.0 * PI * rAvg / spacing));
        float phi = in.opos.y / max(rAvg, 1e-4);
        float2 q = float2(in.opos.x / spacing, phi / (2.0 * PI) * around);
        float2 ci = floor(q);
        float best = 1e9; float br = 0.0;
        for (int j = -1; j <= 1; j++) for (int i = -1; i <= 1; i++) {
            float2 cc = ci + float2(i, j);
            float2 key = float2(cc.x, fmod(fmod(cc.y, around) + around, around)) + in.info.w * 13.0 + in.info.z * 7.0;
            float2 fp = cc + 0.2 + 0.6 * hash22(key);
            float d = length(q - fp);
            if (d < best) { best = d; br = hash12(key + 5.1); }
        }
        dist = best * spacing;
        rnd = br;
    } else {
        spacing = g.misc.w * 0.95;
        float3 q = in.opos / spacing;
        float3 base = floor(q - 0.5);
        float best = 1e9; float br = 0.0;
        for (int k = 0; k <= 1; k++) for (int j = 0; j <= 1; j++) for (int i = 0; i <= 1; i++) {
            float3 cc = base + float3(i, j, k);
            float3 fp = cc + 0.15 + 0.7 * hash33(cc + in.info.w);
            float d = length(q - fp);
            if (d < best) { best = d; br = hash13(cc + 7.7); }
        }
        dist = best * spacing;
        rnd = br;
    }
    // 毛の長さのばらつきと密度
    if (rnd > m.hairDen) discard_fragment();
    float lenF = 0.35 + 0.65 * fract(rnd * 7.31);
    if (h > lenF) discard_fragment();
    float rad = spacing * 0.40 * (1.0 - 0.70 * h / lenF);
    float aa = 0.6 / pxmm;
    float cov = 1.0 - smoothstep(rad - aa, rad + aa, dist);
    // 1px より細い毛は薄く
    cov *= saturate(rad * 2.0 * pxmm * 1.4);
    if (cov < 0.02) discard_fragment();

    float3 T = normalize(in.hdir);
    float3 L = normalize(g.light.xyz);
    float3 V = float3(0, 0, 1);
    float3 Hh = normalize(L + V);
    float TdL = dot(T, L);
    float diffK = sqrt(max(0.0, 1.0 - TdL * TdL));
    float TdH = dot(T, Hh);
    float specK = pow(sqrt(max(0.0, 1.0 - TdH * TdH)), 60.0);
    float3 lightCol = float3(1.0, 0.975, 0.94) * g.light.w;
    float selfShadow = mix(0.45, 1.0, h / lenF);
    float3 N = normalize(in.wn);
    float facing = saturate((dot(N, L) + 0.5) / 1.5);
    float3 hc = m.hair * mix(0.85, 1.15, fract(rnd * 3.7));
    float3 col = hc * (lightCol * diffK * facing * 0.75 + float3(0.26, 0.27, 0.29) * saturate(N.z * 0.5 + 0.6)) * selfShadow
               + lightCol * specK * 0.035 * facing * selfShadow * (0.4 + dot(hc, float3(0.33)));
    return float4(tonemap(col), cov);
}

// ---------------- 後翅（半透明の膜） ----------------
float4 membraneColor(VOut in, constant Globals& g);

fragment float4 fAlpha(VOut in [[stage_in]], constant Globals& g [[buffer(0)]]) {
    int part = int(in.info.x + 0.5);
    float3 o = in.opos;
    float k = in.ext.w;
    if (part == P_PROPBLUR) {
        // 回転するプロペラの残像：外へ向かって薄く、羽根2枚分の濃淡
        float r = length(o.xy) / 6.6;
        float ang = atan2(o.y, o.x);
        float blade = 0.5 + 0.5 * cos(2.0 * ang);
        float tip = smoothstep(0.86, 0.95, r) * smoothstep(1.0, 0.95, r);
        float a = (0.035 + 0.07 * blade * smoothstep(1.0, 0.25, r)) * smoothstep(1.0, 0.93, r) + tip * 0.10 + smoothstep(0.16, 0.10, r) * 0.6;
        float3 c = float3(0.05, 0.05, 0.055) + tip * 0.10;
        return float4(tonemap(c) * a, a);
    }
    if (part == P_FLASH) {
        // 砲口の炎：芯は白く、外は橙で加算気味に光る
        float r = length(o * float3(0.8, 1.0, 1.0));
        float core = exp(-r * r * 6.0);
        float edge = exp(-r * r * 2.2);
        float3 c = mix(float3(2.2, 0.9, 0.2), float3(3.0, 2.6, 1.6), core) * edge * k;
        float a = saturate(edge * 0.55 * k);
        return float4(tonemap(c), a * 0.6);
    }
    if (part == P_GLOW) {
        float r = length(o.xy);
        float seed = in.info.w;
        if (seed > 9.5) {
            // ライトのにじみ（色つき）
            float3 col = seed < 10.5 ? float3(0.15, 1.0, 1.3) : (seed < 11.5 ? float3(1.4, 0.18, 0.9) : float3(1.5, 0.85, 0.12));
            float i = exp(-r * r * 4.5) * 0.55 * k;
            return float4(col * i, 0.0);
        }
        float i = exp(-r * r * 3.0) * 0.32 * k;
        float3 c = float3(0.25, 1.0, 0.7) * i;
        return float4(c, 0.0);
    }
    if (part == P_BEAM) {
        // 牽引ビーム：縁ほど明るい円錐、下へ流れるすじ
        float rr = length(o.xy) / max(mix(1.0, 0.16, saturate(o.z)), 0.05);
        float rim = 0.35 + 0.65 * smoothstep(0.4, 1.0, rr);
        float streak = 0.75 + 0.25 * sin(atan2(o.y, o.x) * 9.0 + o.z * 6.0 + g.misc.y * 9.0);
        float fade = smoothstep(1.0, 0.75, o.z) * (0.55 + 0.45 * (1.0 - o.z));
        float i = rim * streak * fade * 0.55 * k;
        return float4(float3(0.35, 1.0, 0.75) * i, i * 0.12);
    }
    if (part == P_GLASS) {
        // ガラスのドーム：縁で反射が強まり、中が透けて見える
        float3 N = normalize(in.wn);
        float NdV = saturate(N.z);
        float F = 0.06 + 0.94 * pow(1.0 - NdV, 4.0);
        float3 L = normalize(g.light.xyz);
        float3 R = reflect(float3(0, 0, -1), N);
        float3 env = envLight(R, L);
        float3 c = float3(0.30, 0.55, 0.50) * 0.08 + env * F * 0.9;
        float a = saturate(0.10 + 0.75 * F);
        return float4(tonemap(c) * a, a);
    }
    return membraneColor(in, g);
}

float4 membraneColor(VOut in, constant Globals& g) {
    int species = int(g.misc.z + 0.5);
    float3 o = in.opos;
    float3 N = normalize(in.wn);
    if (N.z < 0.0) N = -N;
    // 翅脈：付け根から放射状に伸びる線と横脈
    float ang = atan2(o.y, max(o.x, 0.05));
    float radial = 1.0 - smoothstep(0.02, 0.06, abs(fract(ang * 7.0) - 0.5) - 0.42);
    float cross_ = 1.0 - smoothstep(0.02, 0.05, abs(fract(length(o.xy) * (species == 6 ? 1.1 : 0.45)) - 0.5) - 0.45);
    float vein = saturate(max(radial, cross_ * 0.6));
    float3 tint = species == 6 ? float3(0.30, 0.24, 0.18) : float3(0.20, 0.13, 0.07);
    float3 L = normalize(g.light.xyz);
    float3 H = normalize(L + float3(0, 0, 1));
    float spec = pow(saturate(dot(N, H)), 80.0) * 2.0;
    float3 col = mix(tint, tint * 0.25, vein) * (0.5 + 0.5 * saturate(dot(N, L))) * g.light.w * 0.6 + spec;
    float a = mix(0.28, 0.75, vein) + spec * 0.2;
    a = saturate(a);
    float3 c = tonemap(col);
    return float4(c * a, a);
}

// ---------------- 剛毛・棘（リボン） ----------------
vertex VOut vRib(uint vid [[vertex_id]], const device RibV* R [[buffer(0)]], constant Globals& g [[buffer(2)]]) {
    RibV r = R[vid];
    VOut o;
    float3 p = float3(r.p);
    o.pos = g.viewProj * float4(p, 1.0);
    o.wpos = p;
    o.wn = float3(0, 0, 1);
    o.opos = float3(r.t, r.alpha, r.kind);
    o.hdir = float3(1, 0, 0);
    o.info = float4(9, 0, 0, 0);
    o.ext = float4(0);
    o.shell = 0;
    o.hairLen = 0;
    return o;
}

fragment float4 fRib(VOut in [[stage_in]], constant Globals& g [[buffer(0)]]) {
    float t = in.opos.x;
    float a = in.opos.y;
    int kind = int(in.opos.z + 0.5);
    float3 c;
    if (kind == 0) c = float3(0.012, 0.009, 0.007);          // 黒い棘
    else if (kind == 1) c = float3(0.10, 0.075, 0.055);      // 茶色い細毛
    else if (kind == 2) c = float3(0.90, 0.89, 0.86);        // 白い毛
    else if (kind == 3) c = float3(0.16, 0.11, 0.065);       // 淡い褐色の毛
    else if (kind == 4) c = float3(0.24, 0.075, 0.022);      // 赤褐色の長毛（タランチュラ）
    else c = float3(0.22, 0.18, 0.11);                        // 金色の短毛（アリ）
    float lit = 0.75 + 0.5 * t;
    float3 col = c * (float3(0.32, 0.33, 0.35) + float3(1.0, 0.975, 0.94) * g.light.w * 0.45 * lit);
    col += float3(0.25) * smoothstep(0.35, 0.6, t) * (1.0 - smoothstep(0.6, 0.85, t)) * (kind == 0 ? 0.8 : 0.3);
    return float4(tonemap(col), saturate(a));
}

// ---------------- 影 ----------------
vertex ShOut vBlobShadow(uint vid [[vertex_id]], uint iid [[instance_id]],
                         const device PN* V [[buffer(0)]],
                         const device BlobInst* I [[buffer(1)]],
                         constant Globals& g [[buffer(2)]]) {
    BlobInst b = I[iid];
    float3 nn = float3(V[vid].n);
    float3x3 nm = float3x3(b.nm0.xyz, b.nm1.xyz, b.nm2.xyz);
    float3 wn = normalize(nm * nn);
    float3 wp = (b.model * float4(float3(V[vid].p), 1.0)).xyz + wn * b.info.y * g.shadow.w;
    float3 L = normalize(g.light.xyz);
    float3 pg = wp - L * (wp.z / L.z);
    ShOut o;
    o.pos = g.viewProj * float4(pg.xy, 0.0, 1.0);
    o.h = wp.z;
    return o;
}

vertex ShOut vCapShadow(uint vid [[vertex_id]], uint iid [[instance_id]],
                        const device packed_float3* M [[buffer(0)]],
                        const device CapInst* I [[buffer(1)]],
                        constant Globals& g [[buffer(2)]]) {
    CapInst c = I[iid];
    CapGeo G = capsuleGeo(float3(M[vid]), c);
    float3 wp = G.pos + G.nrm * c.info.z * g.shadow.w;
    float3 L = normalize(g.light.xyz);
    float3 pg = wp - L * (wp.z / L.z);
    ShOut o;
    o.pos = g.viewProj * float4(pg.xy, 0.0, 1.0);
    o.h = wp.z;
    return o;
}

fragment float4 fShadow(ShOut in [[stage_in]], constant Globals& g [[buffer(0)]]) {
    float v = exp(-max(in.h, 0.0) / g.shadow.y);
    return float4(v, v, v, v);
}

// ---------------- 影の合成（全画面） ----------------
struct QOut { float4 pos [[position]]; float2 uv; };

vertex QOut vQuad(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    QOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

fragment float4 fComposite(QOut in [[stage_in]], texture2d<float> sh [[texture(0)]], constant Globals& g [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_zero);
    float a = sh.sample(s, in.uv).r * g.shadow.x;
    float2 w = float2(g.vp.x + in.uv.x * g.vp.z, g.vp.y + (1.0 - in.uv.y) * g.vp.w);
    for (int i = 0; i < 2; i++) {
        float4 e = g.ell[i * 2];
        float4 f = g.ell[i * 2 + 1];
        float2 d = w - e.xy;
        float c = cos(-f.x), sn = sin(-f.x);
        d = float2(c * d.x - sn * d.y, sn * d.x + c * d.y);
        float r = length(d / e.zw);
        float ao = (1.0 - smoothstep(0.15, 1.35, r)) * f.z * exp(-f.y * 0.35);
        a = 1.0 - (1.0 - a) * (1.0 - ao);
    }
    for (int i = 0; i < 10; i++) {
        float4 ft = g.feet[i];
        if (ft.w <= 0.0) continue;
        float d = length(w - ft.xy);
        float c = (1.0 - smoothstep(0.0, ft.w, d)) * ft.z * g.shadow.z;
        a = 1.0 - (1.0 - a) * (1.0 - c);
    }
    return float4(0.0, 0.0, 0.0, saturate(a));
}
