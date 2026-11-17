## Projeto 3 – Ray Tracer em WGSL (WebGPU)

Path tracer feito sobre o [template do curso](https://github.com/Gustavobb/raytracing-wgsl-template).
Todas as cenas do template foram implementadas e comparadas com o
[gabarito](https://gubebra.itch.io/raytracing). Além delas, há uma **primitiva nova (cilindro)** e
**duas cenas novas** (`Cylinders` e `Temple`).

Aluno(s): _preencher_

### Como rodar

O navegador precisa ter WebGPU (Chrome/Edge atualizados). Os arquivos precisam ser servidos por HTTP
(abrir o `index.html` direto não funciona):

- VS Code: extensão **Live Server** → `CTRL + Shift + P` → `Live Server: Open with Live Server`; ou
- terminal, na pasta do projeto: `python -m http.server 5500` e abrir http://localhost:5500

Escolha a cena no menu **Scene** do painel à direita.

### Controles

Todos os parâmetros podem ser alterados no painel (dica: clique no valor e use a rolagem do mouse).
Câmera: `WASD` move, `Q`/`E` desce/sobe, setas e `Z`/`X` giram o ponto para onde ela olha.

### O que foi implementado

| Conceito | Cenas | Status |
|---|---|---|
| D  | Basic, Metal, Fuzz | ✅ |
| C  | Specular, Emissive | ✅ |
| C+ | Dielectric, Spheres, Night | ✅ |
| B  | Cubes, Cornell, Mirror, Infinite | ✅ |
| B+ | Bunny, Suzanne + cena nova (`Temple`) | ✅ |
| A  | Primitiva nova: cilindro (`Cylinders`) | ✅ |
| A+ | Rotation, Everything | ✅ |

**`src/shaders/raytracer.wgsl`**
- `render`: várias amostras por pixel com jitter (anti-aliasing), desfoque de lente da câmera do
  template e **acumulação progressiva**: `rtfb` guarda a soma das amostras (`xyz`) e quantos frames
  foram somados (`w`); a imagem exibida é a média, que é zerada quando a cena ou a câmera muda.
- `trace`: path tracing com até `maxBounces` quiques. Cada quique multiplica a atenuação pela cor do
  material; o céu (gradiente + sol) e os objetos emissivos somam luz. O novo raio sai levemente
  afastado da superfície para evitar auto-interseção ("acne").
- `check_ray_collision`: testa esferas, quads, caixas, cilindros e malhas e fica com o `t` mais próximo.
  Caixas, cilindros e malhas são testados no **espaço local**: o raio é girado pelo quaternion dos
  ângulos de Euler (mesma convenção do gabarito) e a normal volta com o quaternion inverso. Nas malhas
  o raio também é dividido pela escala (a normal usa a inversa-transposta) e os triângulos só são
  testados se o raio acertar a bounding box (`AABB_intersect`). `showBB = 1` desenha a bounding box.
  A normal final sempre aponta contra o raio e `frontface` diz se o raio está entrando no objeto.
- Materiais: `lambertian`, `metal`, `dielectric` (Snell + reflexão interna total + Schlick) e `emmisive`.

**`src/shaders/shapes.wgsl`**: `hit_sphere` (testa as duas raízes, então funciona de dentro de um
vidro), `hit_cylinder` (novo) e ajustes em `hit_box` (acerta a face de saída quando o raio começa
dentro da caixa) e `hit_triangle` (ignora raio paralelo para não gerar NaN).

### Modelo de material

`material = [smoothness, absorption, specular, light]`

| Condição | Comportamento |
|---|---|
| `light > 0` | emissivo: emite `cor * light` e o caminho termina |
| `smoothness < 0` | dielétrico: `specular` = índice de refração, `absorption` = fuzz da refração |
| `smoothness > 0` | com probabilidade `specular` reflete como metal (fuzz = `absorption`), misturando a direção com a difusa conforme `smoothness`; senão é difuso |
| `smoothness = 0` | lambertiano; `absorption` = chance do raio ser absorvido |

A especularidade é branca: no reflexo especular a cor vai de branco (superfície áspera) até a cor do
objeto (`smoothness = 1`, metal polido), que é o que deixa as esferas da cena `Metal` coloridas.

### Primitiva nova: cilindro

`new Cylinder(centro, cor, rotação [rad], raio, meiaAltura, material)` (`src/objects.js`). Eixo no Y
local, com tampas. A interseção resolve a equação do círculo `x² + z² = r²` para a lateral (limitada
pela altura) e os planos `y = ±meiaAltura` para as tampas, e fica com o menor `t` válido. Aceita
rotação e todos os materiais, e pode ser editado/adicionado pelo painel (pasta `Cylinder(s)`).

Os cilindros usam um buffer **uniform** (`MAX_CYLINDERS = 10`) porque o WebGPU permite por padrão
só 8 storage buffers por shader, e o template já usa os 8.

### Cenas novas (`src/scenes.js`)

- **Cylinders**: cilindros difuso, de vidro (na frente do vermelho, para ver a refração), de ouro
  inclinado, uma moeda espelhada, um tubo de neon emissivo e um plástico brilhante girado.
- **Temple**: templo ao pôr do sol com colunas (cilindros), capitéis e vigas (caixas), uma estátua de
  ouro (Suzanne) no pedestal, lanternas emissivas, esfera de vidro, esfera espelhada e uma coluna caída.

### Correções no template

- `getModule` (`src/util.js`) referenciava uma variável `file` inexistente, o que escondia o erro real
  de compilação do WGSL; agora mostra a mensagem com a linha e só aborta em erro (não em warning).
- A acumulação era religada por um timer de 400 ms; se nenhum frame rodasse nesse intervalo (fps
  baixo ou aba em segundo plano), a cena anterior ficava "fantasma" na nova. Agora pelo menos um frame
  é sempre renderizado com a acumulação zerada (`main.js`).
