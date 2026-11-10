// URL base del API.
//  - Vacio ("")  => mismo origen: nginx (ECS) o CloudFront enrutan /api/* al backend.
//  - Si la pagina se abre directo desde el endpoint de sitio web de S3 (http://...s3-website...),
//    se usa API_URL_DIRECTA (IP/DNS publico del task de ECS). Se reemplaza en el despliegue.
window.API_URL_DIRECTA = "";
window.API_BASE = location.hostname.includes("s3-website") ? window.API_URL_DIRECTA : "";
