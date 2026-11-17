const THREAD_COUNT = 16;
const RAY_TMIN = 0.0001;
const RAY_TMAX = 100.0;
const PI = 3.1415927f;
const FRAC_1_PI = 0.31830987f;
const FRAC_2_PI = 1.5707964f;

// distância usada para afastar o novo raio da superfície (evita "acne" de auto-interseção)
const SURFACE_EPSILON = 0.001;

// precisa ser igual a MAX_CYLINDERS do main.js (o buffer de cilindros é um uniform de tamanho fixo)
const MAX_CYLINDERS = 10;

@group(0) @binding(0)
  var<storage, read_write> fb : array<vec4f>;

@group(0) @binding(1)
  var<storage, read_write> rtfb : array<vec4f>;

@group(1) @binding(0)
  var<storage, read_write> uniforms : array<f32>;

@group(2) @binding(0)
  var<storage, read_write> spheresb : array<sphere>;

@group(2) @binding(1)
  var<storage, read_write> quadsb : array<quad>;

@group(2) @binding(2)
  var<storage, read_write> boxesb : array<box>;

@group(2) @binding(3)
  var<storage, read_write> trianglesb : array<triangle>;

@group(2) @binding(4)
  var<storage, read_write> meshb : array<mesh>;

// nova primitiva: cilindros. Usa um buffer uniform (e não storage) para não estourar o
// limite padrão de 8 storage buffers por estágio do WebGPU (já usamos os 8).
@group(2) @binding(5)
  var<uniform> cylindersb : array<cylinder, MAX_CYLINDERS>;

struct ray {
  origin : vec3f,
  direction : vec3f,
};

struct sphere {
  transform : vec4f,
  color : vec4f,
  material : vec4f,
};

struct quad {
  Q : vec4f,
  u : vec4f,
  v : vec4f,
  color : vec4f,
  material : vec4f,
};

struct box {
  center : vec4f,
  radius : vec4f,
  rotation: vec4f,
  color : vec4f,
  material : vec4f,
};

struct cylinder {
  center : vec4f,   // xyz = centro
  size : vec4f,     // x = raio, y = meia altura (eixo Y local)
  rotation : vec4f, // xyz = rotação em ângulos de Euler (radianos)
  color : vec4f,
  material : vec4f,
};

struct triangle {
  v0 : vec4f,
  v1 : vec4f,
  v2 : vec4f,
};

struct mesh {
  transform : vec4f,
  scale : vec4f,
  rotation : vec4f,
  color : vec4f,
  material : vec4f,
  min : vec4f,
  max : vec4f,
  show_bb : f32,
  start : f32,
  end : f32,
};

struct material_behaviour {
  scatter : bool,
  direction : vec3f,
};

struct camera {
  origin : vec3f,
  lower_left_corner : vec3f,
  horizontal : vec3f,
  vertical : vec3f,
  u : vec3f,
  v : vec3f,
  w : vec3f,
  lens_radius : f32,
};

struct hit_record {
  t : f32,
  p : vec3f,
  normal : vec3f,
  object_color : vec4f,
  object_material : vec4f,
  frontface : bool,
  hit_anything : bool,
};

fn ray_at(r: ray, t: f32) -> vec3f
{
  return r.origin + t * r.direction;
}

fn get_ray(cam: camera, uv: vec2f, rng_state: ptr<function, u32>) -> ray
{
  var rd = cam.lens_radius * rng_next_vec3_in_unit_disk(rng_state);
  var offset = cam.u * rd.x + cam.v * rd.y;
  return ray(cam.origin + offset, normalize(cam.lower_left_corner + uv.x * cam.horizontal + uv.y * cam.vertical - cam.origin - offset));
}

fn get_camera(lookfrom: vec3f, lookat: vec3f, vup: vec3f, vfov: f32, aspect_ratio: f32, aperture: f32, focus_dist: f32) -> camera
{
  var camera = camera();
  camera.lens_radius = aperture / 2.0;

  var theta = degrees_to_radians(vfov);
  var h = tan(theta / 2.0);
  var w = aspect_ratio * h;

  camera.origin = lookfrom;
  camera.w = normalize(lookfrom - lookat);
  camera.u = normalize(cross(vup, camera.w));
  camera.v = cross(camera.u, camera.w);

  camera.lower_left_corner = camera.origin - w * focus_dist * camera.u - h * focus_dist * camera.v - focus_dist * camera.w;
  camera.horizontal = 2.0 * w * focus_dist * camera.u;
  camera.vertical = 2.0 * h * focus_dist * camera.v;

  return camera;
}

fn envoriment_color(direction: vec3f, color1: vec3f, color2: vec3f) -> vec3f
{
  var unit_direction = normalize(direction);
  var t = 0.5 * (unit_direction.y + 1.0);
  var col = (1.0 - t) * color1 + t * color2;

  var sun_direction = normalize(vec3(uniforms[13], uniforms[14], uniforms[15]));
  var sun_color = int_to_rgb(i32(uniforms[17]));
  var sun_intensity = uniforms[16];
  var sun_size = uniforms[18];

  var sun = clamp(dot(sun_direction, unit_direction), 0.0, 1.0);
  col += sun_color * max(0, (pow(sun, sun_size) * sun_intensity));

  return col;
}

// Testa o raio contra todos os objetos da cena e devolve a interseção mais próxima.
// Objetos com rotação (caixas, cilindros e malhas) são testados no espaço local deles:
// o quaternion q (vindo dos ângulos de Euler) leva o raio do mundo para o espaço local e
// q⁻¹ traz a normal de volta (mesma convenção do gabarito; o t é o mesmo nos dois espaços).
fn check_ray_collision(r: ray, t_max: f32) -> hit_record
{
  var spheresCount = i32(uniforms[19]);
  var quadsCount = i32(uniforms[20]);
  var boxesCount = i32(uniforms[21]);
  var trianglesCount = i32(uniforms[22]);
  var meshCount = i32(uniforms[27]);
  var cylindersCount = min(i32(uniforms[28]), MAX_CYLINDERS);

  var record = hit_record(RAY_TMAX, vec3f(0.0), vec3f(0.0), vec4f(0.0), vec4f(0.0), false, false);
  var closest = record;
  closest.t = t_max;

  // esferas
  for (var i = 0; i < spheresCount; i = i + 1)
  {
    var s = spheresb[i];
    var rec = record;
    hit_sphere(s.transform.xyz, s.transform.w, r, &rec, closest.t);
    if (rec.hit_anything)
    {
      closest = rec;
      closest.object_color = s.color;
      closest.object_material = s.material;
    }
  }

  // quads (só são visíveis pela frente, igual ao template)
  for (var i = 0; i < quadsCount; i = i + 1)
  {
    var q = quadsb[i];
    var rec = record;
    hit_quad(r, q.Q, q.u, q.v, &rec, closest.t);
    if (rec.hit_anything)
    {
      closest = rec;
      closest.object_color = q.color;
      closest.object_material = q.material;
    }
  }

  // caixas com rotação
  for (var i = 0; i < boxesCount; i = i + 1)
  {
    var b = boxesb[i];
    var rotation = quaternion_from_euler(b.rotation.xyz);
    var local_ray = rotate_ray_quaternion(r, b.center.xyz, rotation);
    var rec = record;
    hit_box(local_ray, b.center.xyz, b.radius.xyz, &rec, closest.t);
    if (rec.hit_anything)
    {
      closest = rec;
      closest.p = ray_at(r, rec.t);
      closest.normal = rotate_vector(rec.normal, q_inverse(rotation));
      closest.object_color = b.color;
      closest.object_material = b.material;
    }
  }

  // cilindros com rotação (nova primitiva)
  for (var i = 0; i < cylindersCount; i = i + 1)
  {
    var c = cylindersb[i];
    var rotation = quaternion_from_euler(c.rotation.xyz);
    var local_ray = rotate_ray_quaternion(r, c.center.xyz, rotation);
    var rec = record;
    hit_cylinder(local_ray, c.center.xyz, c.size.x, c.size.y, &rec, closest.t);
    if (rec.hit_anything)
    {
      closest = rec;
      closest.p = ray_at(r, rec.t);
      closest.normal = rotate_vector(rec.normal, q_inverse(rotation));
      closest.object_color = c.color;
      closest.object_material = c.material;
    }
  }

  // malhas (bunny, suzanne): mundo -> local = translação, rotação e escala inversa.
  // A direção local não é normalizada, assim o t encontrado vale também no espaço do mundo.
  for (var i = 0; i < meshCount; i = i + 1)
  {
    var m = meshb[i];
    var rotation = quaternion_from_euler(m.rotation.xyz);
    var inverse_rotation = q_inverse(rotation);
    var scale = m.scale.xyz;
    var local_ray = ray(rotate_vector(r.origin - m.transform.xyz, rotation) / scale, rotate_vector(r.direction, rotation) / scale);

    // debug: desenha a bounding box no lugar da malha
    if (m.show_bb > 0.5)
    {
      var rec = record;
      hit_box(local_ray, (m.min.xyz + m.max.xyz) * 0.5, (m.max.xyz - m.min.xyz) * 0.5, &rec, closest.t);
      if (rec.hit_anything)
      {
        closest = rec;
        closest.p = ray_at(r, rec.t);
        closest.normal = normalize(rotate_vector(rec.normal / scale, inverse_rotation));
        closest.object_color = m.color;
        closest.object_material = m.material;
      }
      continue;
    }

    // aceleração: só testa os triângulos se o raio acertar a bounding box
    if (!AABB_intersect(local_ray, m.min.xyz, m.max.xyz))
    {
      continue;
    }

    var hit_mesh = false;
    for (var j = i32(m.start); j < i32(m.end); j = j + 1)
    {
      var tri = trianglesb[j];
      var rec = record;
      hit_triangle(local_ray, tri.v0.xyz, tri.v1.xyz, tri.v2.xyz, &rec, closest.t);
      if (rec.hit_anything)
      {
        closest = rec;
        hit_mesh = true;
      }
    }

    if (hit_mesh)
    {
      // normal: inversa-transposta da transformação local -> mundo = q⁻¹ * (1 / escala)
      closest.p = ray_at(r, closest.t);
      closest.normal = normalize(rotate_vector(closest.normal / scale, inverse_rotation));
      closest.object_color = m.color;
      closest.object_material = m.material;
    }
  }

  // "Debug Show Look At": pequena esfera vermelha emissiva no ponto para onde a câmera olha
  if (uniforms[26] > 0.5)
  {
    var rec = record;
    hit_sphere(vec3f(uniforms[23], uniforms[24], uniforms[25]), 0.05, r, &rec, closest.t);
    if (rec.hit_anything)
    {
      closest = rec;
      closest.object_color = vec4f(1.0, 0.0, 0.0, 1.0);
      closest.object_material = vec4f(0.0, 0.0, 0.0, 1.0);
    }
  }

  // a normal sempre aponta contra o raio; frontface diz se entramos ou saímos do objeto
  closest.frontface = dot(r.direction, closest.normal) < 0.0;
  if (!closest.frontface)
  {
    closest.normal = -closest.normal;
  }

  return closest;
}

// Difuso (Lambert): normal + vetor unitário aleatório gera direções com distribuição cosseno.
// "absorption" é a probabilidade da superfície absorver o raio (ele morre e não traz luz).
fn lambertian(normal : vec3f, absorption: f32, random_sphere: vec3f, rng_state: ptr<function, u32>) -> material_behaviour
{
  var direction = normal + random_sphere;
  if (dot(direction, direction) < 1e-8)
  {
    direction = normal;
  }

  var scatter = rng_next_float(rng_state) >= absorption;
  return material_behaviour(scatter, normalize(direction));
}

// Metal: reflexão perfeita perturbada pelo fuzz. Se cair para dentro da superfície, é absorvido.
fn metal(normal : vec3f, direction: vec3f, fuzz: f32, random_sphere: vec3f) -> material_behaviour
{
  var reflected = reflect(normalize(direction), normal);
  var scattered = normalize(reflected + min(fuzz, 1.0) * random_sphere);
  return material_behaviour(dot(scattered, normal) > 0.0, scattered);
}

// Aproximação de Schlick para a refletância de Fresnel
fn schlick(cosine: f32, ri: f32) -> f32
{
  var r0 = (1.0 - ri) / (1.0 + ri);
  r0 = r0 * r0;
  return r0 + (1.0 - r0) * pow(1.0 - cosine, 5.0);
}

// Dielétrico (vidro): refrata pela lei de Snell ou reflete (reflexão interna total / Fresnel).
// Convenção do "Ray Tracing in One Weekend": entrando no objeto a razão é 1/n, saindo é n.
fn dielectric(normal : vec3f, r_direction: vec3f, refraction_index: f32, frontface: bool, random_sphere: vec3f, fuzz: f32, rng_state: ptr<function, u32>) -> material_behaviour
{
  var ior = max(refraction_index, 0.0001);
  var ri = select(ior, 1.0 / ior, frontface);

  var unit_direction = normalize(r_direction);
  var cos_theta = clamp(dot(-unit_direction, normal), 0.0, 1.0);
  var sin_theta = sqrt(1.0 - cos_theta * cos_theta);

  var direction = refract(unit_direction, normal, ri);
  var cannot_refract = ri * sin_theta > 1.0 || dot(direction, direction) < 1e-6;

  if (cannot_refract || schlick(cos_theta, ri) > rng_next_float(rng_state))
  {
    direction = reflect(unit_direction, normal);
  }

  return material_behaviour(true, normalize(direction + fuzz * random_sphere));
}

// Emissivo: não espalha o raio. O campo "direction" carrega a luz emitida (cor * intensidade).
fn emmisive(color: vec3f, light: f32) -> material_behaviour
{
  return material_behaviour(false, color * light);
}

// Path tracing: segue o raio pelos quiques acumulando a atenuação (color) e a luz recebida (light).
// Material = [smoothness, absorption, specular, light]:
//   light > 0          -> emissivo
//   smoothness < 0     -> dielétrico (specular = índice de refração, absorption = fuzz)
//   smoothness > 0     -> com probabilidade "specular" faz um reflexo especular (metal com
//                         fuzz = absorption, misturado ao difuso pela smoothness); senão é difuso
//   smoothness == 0    -> lambertiano (absorption = chance de absorver o raio)
fn trace(r: ray, rng_state: ptr<function, u32>) -> vec3f
{
  var maxbounces = i32(uniforms[2]);
  var light = vec3f(0.0);
  var color = vec3f(1.0);
  var r_ = r;

  var backgroundcolor1 = int_to_rgb(i32(uniforms[11]));
  var backgroundcolor2 = int_to_rgb(i32(uniforms[12]));
  var behaviour = material_behaviour(true, vec3f(0.0));

  for (var j = 0; j < maxbounces; j = j + 1)
  {
    var rec = check_ray_collision(r_, RAY_TMAX);

    // não acertou nada: a luz vem do céu/sol
    if (!rec.hit_anything)
    {
      light += color * envoriment_color(r_.direction, backgroundcolor1, backgroundcolor2);
      break;
    }

    var smoothness = rec.object_material.x;
    var absorption = rec.object_material.y;
    var specular = rec.object_material.z;
    var emission = rec.object_material.w;
    var object_color = rec.object_color.xyz;
    var random_sphere = rng_next_vec3_in_unit_sphere(rng_state);

    if (emission > 0.0)
    {
      behaviour = emmisive(object_color, emission);
      light += color * behaviour.direction;
      break;
    }

    if (smoothness < 0.0)
    {
      behaviour = dielectric(rec.normal, r_.direction, specular, rec.frontface, random_sphere, absorption, rng_state);
      color *= object_color;
    }
    else if (smoothness > 0.0 && rng_next_float(rng_state) < specular)
    {
      var diffuse = lambertian(rec.normal, 0.0, random_sphere, rng_state);
      var mirror = metal(rec.normal, r_.direction, absorption, random_sphere);
      var direction = normalize(mix(diffuse.direction, mirror.direction, smoothness));
      behaviour = material_behaviour(dot(direction, rec.normal) > 0.0, direction);

      // a especularidade é branca: quanto menos liso, mais o reflexo puxa para o branco;
      // metal liso (smoothness = 1) reflete com a cor do objeto
      color *= mix(vec3f(1.0), object_color, smoothness);
    }
    else
    {
      behaviour = lambertian(rec.normal, absorption, random_sphere, rng_state);
      color *= object_color;
    }

    if (!behaviour.scatter)
    {
      break;
    }

    // novo raio sai do ponto de contato, deslocado para o lado em que segue
    // (fora do objeto na reflexão, dentro na refração)
    var offset = select(-SURFACE_EPSILON, SURFACE_EPSILON, dot(behaviour.direction, rec.normal) > 0.0);
    r_ = ray(rec.p + rec.normal * offset, behaviour.direction);
  }

  return light;
}

@compute @workgroup_size(THREAD_COUNT, THREAD_COUNT, 1)
fn render(@builtin(global_invocation_id) id : vec3u)
{
    var rez = uniforms[1];
    var time = u32(uniforms[0]);

    // init_rng (random number generator) we pass the pixel position, resolution and frame
    var rng_state = init_rng(vec2(id.x, id.y), vec2(u32(rez)), time);

    var fragCoord = vec2f(f32(id.x), f32(id.y));

    // Camera
    var lookfrom = vec3(uniforms[7], uniforms[8], uniforms[9]);
    var lookat = vec3(uniforms[23], uniforms[24], uniforms[25]);

    // Get camera
    var cam = get_camera(lookfrom, lookat, vec3(0.0, 1.0, 0.0), uniforms[10], 1.0, uniforms[6], uniforms[5]);
    var samples_per_pixel = max(i32(uniforms[4]), 1);

    // várias amostras por pixel, cada uma com um deslocamento aleatório dentro do pixel (anti-aliasing)
    var color = vec3f(0.0);
    for (var s = 0; s < samples_per_pixel; s = s + 1)
    {
      var uv = (fragCoord + sample_square(&rng_state)) / vec2(rez);
      color += trace(get_ray(cam, uv, &rng_state), &rng_state);
    }
    color /= f32(samples_per_pixel);

    var map_fb = mapfb(id.xy, rez);

    // acumulação progressiva: rtfb guarda a soma das amostras (xyz) e quantos frames somou (w).
    // Quando a cena/câmera muda, should_accumulate = 0 e a soma recomeça.
    var should_accumulate = uniforms[3];
    var accumulated = rtfb[map_fb];
    if (should_accumulate < 0.5)
    {
      accumulated = vec4f(0.0);
    }
    accumulated += vec4f(color, 1.0);
    rtfb[map_fb] = accumulated;

    // Set the color to the framebuffer
    fb[map_fb] = vec4(linear_to_gamma(accumulated.xyz / accumulated.w), 1.0);
}
