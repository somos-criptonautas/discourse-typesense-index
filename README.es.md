# discourse-typesense-index

[ENGLISH](README.md) | **ESPAÑOL**

Mantenido por Criptonautas. Sin afiliación ni respaldo de Discourse (Civilized Discourse Construction Kit, Inc.).

Mantiene una colección de Typesense autoalojada sincronizada con los posts de Discourse que un
visitante anónimo puede leer. Sin interfaz de búsqueda, sin proxy, sin gems. Buscas desde tu propio frontend.

## Qué se indexa

Un documento por post público (`id` = id del post):
`topic_id, post_number, title, text, url, username, category_id, category, tags, like_count, created_at`.

Un post se indexa solo si se cumplen todas estas condiciones:

- el sitio no tiene `login_required`
- es un post normal, no un susurro ni una acción menor
- su tema está listado, no oculto de listados
- su categoría (o la categoría padre) no está en `typesense_excluded_categories`
- es un primer post, o una respuesta de al menos `typesense_min_reply_length` caracteres
- `Guardian.new.can_see_post?` lo permite. Eso descarta categorías privadas, mensajes privados, posts ocultos o
  eliminados y todo lo que restrinjan plugins como category lockdown.

Las etiquetas ocultas para visitantes anónimos se excluyen de `tags`. `text` es el post depurado
igual que lo hace la búsqueda propia de Discourse.

## Ajustes

| Ajuste | Por defecto | |
|---|---|---|
| `typesense_indexer_enabled` | off | interruptor general |
| `typesense_url` | `http://localhost:8108` | URL base de Typesense, vista desde el contenedor de Discourse; se conserva el prefijo de ruta |
| `typesense_api_key` | | clave de administrador; nunca sale del servidor |
| `typesense_collection` | `discourse_posts` | el alias que busca tu frontend |
| `typesense_excluded_categories` | ninguna | categorías públicas a excluir; sus subcategorías también se excluyen |
| `typesense_min_reply_length` | `20` | las respuestas más cortas se omiten; los primeros posts siempre se indexan |

Activar el plugin, o cambiar cualquiera de estos ajustes, inicia una reconstrucción completa.

## Buscar: una fila por discusión

`url` apunta al post mismo (`/t/slug/<topic_id>/<post_number>`), así que agrupar por tema
da la respuesta que mejor coincide de cada discusión, con un enlace directo a ella:

```js
{
  collection: "discourse_posts",
  q: "monero wallet",
  query_by: "title,text",
  group_by: "topic_id",
  group_limit: 1,
  highlight_fields: "text",
}
```

Para mostrar solo temas, filtra por `post_number:=1`.

## Cómo se mantiene sincronizado

- **En vivo:** los eventos de posts y temas encolan un trabajo `typesense_sync` para ese post o tema.
- **Reconstrucción:** a diario, y cada vez que cambia una categoría o un ajuste. Construye una
  `<colección>_<marca de tiempo>` nueva, cambia el alias a ella y luego elimina las colecciones sobrantes de
  reconstrucciones anteriores o interrumpidas. Las búsquedas nunca ven un índice a medio construir.

## Puesta en marcha

1. Añade a `app.yml` y reconstruye:
   `- git clone https://github.com/somos-criptonautas/discourse-typesense-index.git`
2. Configura `typesense_url` y `typesense_api_key`, y activa `typesense_indexer_enabled`.
   La primera construcción arranca sola. `rake typesense:rebuild` lanza una a mano.
3. Crea una clave solo de búsqueda para el frontend:

   ```bash
   curl -X POST "$TYPESENSE_URL/keys" -H "X-TYPESENSE-API-KEY: $ADMIN_KEY" \
     -d '{"description":"search","actions":["documents:search"],"collections":["discourse_posts*"]}'
   ```

   El índice contiene solo contenido público, así que esta clave es segura para usar en un navegador.

## CI

`.github/workflows/discourse-plugin.yml` ejecuta dos cosas:

- El flujo estándar de plugins de Discourse: rubocop, syntax_tree y los specs dentro de un checkout real de
  Discourse.
- La autocomprobación del cliente HTTP contra un contenedor de servicio de Typesense.

En local: `ruby lib/typesense_indexer/client.rb` y
`LOAD_PLUGINS=1 bin/rspec plugins/discourse-typesense-index/spec` desde un checkout de Discourse.

## Licencia

MIT. Consulta [LICENSE](LICENSE).

Texto de este README bajo [CC BY-NC-SA 4.0](CC-BY-NC-SA-4.0.txt).
