// Esfera: resolve |o + t*d - c|^2 = r^2 (forma com half_b). Tenta a raiz mais próxima e,
// se ela estiver fora do intervalo (ex.: raio saindo de dentro de um vidro), a mais distante.
// Raio negativo inverte a normal (truque da esfera oca do "Ray Tracing in One Weekend").
fn hit_sphere(center: vec3f, radius: f32, r: ray, record: ptr<function, hit_record>, max: f32)
{
  var oc = r.origin - center;
  var a = dot(r.direction, r.direction);
  var half_b = dot(oc, r.direction);
  var c = dot(oc, oc) - radius * radius;
  var discriminant = half_b * half_b - a * c;

  if (discriminant < 0.0)
  {
    record.hit_anything = false;
    return;
  }

  var sqrtd = sqrt(discriminant);
  var t = (-half_b - sqrtd) / a;
  if (t < RAY_TMIN || t > max)
  {
    t = (-half_b + sqrtd) / a;
    if (t < RAY_TMIN || t > max)
    {
      record.hit_anything = false;
      return;
    }
  }

  record.t = t;
  record.p = ray_at(r, t);
  record.normal = (record.p - center) / radius;
  record.hit_anything = true;
}

// NOVA PRIMITIVA: cilindro com tampas, eixo no Y local, centrado em "center".
// Lateral: (ox + t*dx)^2 + (oz + t*dz)^2 = R^2 com |oy + t*dy| <= meia altura.
// Tampas: planos y = +-meia altura com x^2 + z^2 <= R^2. Fica com o menor t válido.
fn hit_cylinder(r: ray, center: vec3f, radius: f32, half_height: f32, record: ptr<function, hit_record>, max: f32)
{
  var o = r.origin - center;
  var d = r.direction;
  var t_hit = max;
  var normal = vec3f(0.0);
  var hit = false;

  // lateral (se o raio não for paralelo ao eixo)
  var a = d.x * d.x + d.z * d.z;
  if (a > 1e-8)
  {
    var half_b = o.x * d.x + o.z * d.z;
    var c = o.x * o.x + o.z * o.z - radius * radius;
    var discriminant = half_b * half_b - a * c;
    if (discriminant >= 0.0)
    {
      var sqrtd = sqrt(discriminant);
      for (var k = 0; k < 2; k = k + 1)
      {
        var t = (-half_b + select(-sqrtd, sqrtd, k == 1)) / a;
        var y = o.y + t * d.y;
        if (t > RAY_TMIN && t < t_hit && abs(y) <= half_height)
        {
          t_hit = t;
          normal = vec3f(o.x + t * d.x, 0.0, o.z + t * d.z) / radius;
          hit = true;
          break;
        }
      }
    }
  }

  // tampas (se o raio não for paralelo a elas)
  if (abs(d.y) > 1e-8)
  {
    for (var k = 0; k < 2; k = k + 1)
    {
      var side = select(-1.0, 1.0, k == 1);
      var t = (side * half_height - o.y) / d.y;
      var x = o.x + t * d.x;
      var z = o.z + t * d.z;
      if (t > RAY_TMIN && t < t_hit && x * x + z * z <= radius * radius)
      {
        t_hit = t;
        normal = vec3f(0.0, side, 0.0);
        hit = true;
      }
    }
  }

  if (!hit)
  {
    record.hit_anything = false;
    return;
  }

  record.t = t_hit;
  record.p = ray_at(r, t_hit);
  record.normal = normal;
  record.hit_anything = true;
}

fn hit_quad(r: ray, Q: vec4f, u: vec4f, v: vec4f, record: ptr<function, hit_record>, max: f32)
{
  var n = cross(u.xyz, v.xyz);
  var normal = normalize(n);
  var D = dot(normal, Q.xyz);
  var w = n / dot(n.xyz, n.xyz);

  var denom = dot(normal, r.direction);
  if (abs(denom) < 0.0001)
  {
    record.hit_anything = false;
    return;
  }

  var t = (D - dot(normal, r.origin)) / denom;
  if (t < RAY_TMIN || t > max)
  {
    record.hit_anything = false;
    return;
  }

  var intersection = ray_at(r, t);
  var planar_hitpt_vector = intersection - Q.xyz;
  var alpha = dot(w, cross(planar_hitpt_vector, v.xyz));
  var beta = dot(w, cross(u.xyz, planar_hitpt_vector));

  if (alpha < 0.0 || alpha > 1.0 || beta < 0.0 || beta > 1.0)
  {
    record.hit_anything = false;
    return;
  }

  if (dot(normal, r.direction) > 0.0)
  {
    record.hit_anything = false;
    return;
  }

  record.t = t;
  record.p = intersection;
  record.normal = normal;
  record.hit_anything = true;
}

fn hit_triangle(r: ray, v0: vec3f, v1: vec3f, v2: vec3f, record: ptr<function, hit_record>, max: f32)
{
  var v1v0 = v1 - v0;
  var v2v0 = v2 - v0;
  var rov0 = r.origin - v0;

  var n = cross(v1v0, v2v0);
  var q = cross(rov0, r.direction);

  // raio paralelo ao triângulo: evita divisão por zero (NaN estragaria a acumulação)
  var det = dot(r.direction, n);
  if (abs(det) < 1e-20)
  {
    record.hit_anything = false;
    return;
  }

  var d = 1.0 / det;

  var u = d * dot(-q, v2v0);
  var v = d * dot(q, v1v0);
  var t = d * dot(-n, rov0);

  if (u < 0.0 || u > 1.0 || v < 0.0 || (u + v) > 1.0)
  {
    record.hit_anything = false;
    return;
  }

  if (t < RAY_TMIN || t > max)
  {
    record.hit_anything = false;
    return;
  }

  record.t = t;
  record.p = ray_at(r, t);
  record.normal = normalize(n);
  record.hit_anything = true;
}

fn hit_box(r: ray, center: vec3f, rad: vec3f, record: ptr<function, hit_record>, t_max: f32)
{
  var m = 1.0 / r.direction;
  var n = m * (r.origin - center);
  var k = abs(m) * rad;

  var t1 = -n - k;
  var t2 = -n + k;

  var tN = max(max(t1.x, t1.y), t1.z);
  var tF = min(min(t2.x, t2.y), t2.z);

  if (tN > tF || tF < 0.0)
  {
    record.hit_anything = false;
    return;
  }

  var t = tN;
  var normal = -sign(r.direction) * step(t1.yzx, t1.xyz) * step(t1.zxy, t1.xyz);

  // origem dentro da caixa (ex.: raio refratado num vidro): usa a face de saída
  if (t < RAY_TMIN)
  {
    t = tF;
    normal = sign(r.direction) * step(t2.xyz, t2.yzx) * step(t2.xyz, t2.zxy);
  }

  if (t < RAY_TMIN || t > t_max)
  {
    record.hit_anything = false;
    return;
  }

  record.t = t;
  record.p = ray_at(r, t);
  record.normal = normal;
  record.hit_anything = true;

  return;
}