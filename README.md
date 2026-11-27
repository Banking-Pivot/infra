# Sistema bancario: cómo ejecutarlo

Este repositorio levanta la infraestructura del sistema (bases de datos, Kafka, Redis y Vault) y, si se quiere, también los once servicios en contenedores. Aquí está la guía para ejecutar todo en una máquina nueva.

## Qué necesitas

- Git.
- Docker Desktop encendido, con 8 GB de memoria asignados si vas a correr los servicios en contenedores.
- JDK 17. Maven no hace falta: cada servicio trae su `mvnw`.
- IntelliJ IDEA, solo si prefieres ejecutar los servicios desde el IDE.
- Postman o el Postman CLI, para las pruebas.

## 1. Clonar los repositorios

Los trece repositorios deben quedar uno al lado del otro, en la misma carpeta y con su nombre original, porque se buscan entre sí por ruta relativa.

```bash
mkdir banking && cd banking
for repo in infra banking-config config-server discovery-server api-gateway \
            auth-service customer-service product-service account-service \
            credit-service transaction-service card-service yanki-service; do
  git clone https://github.com/Banking-Pivot/$repo.git
done
```

## 2. Levantar la infraestructura

```bash
cd infra
cp .env.example .env
docker compose up -d --wait
```

En Windows, `copy .env.example .env`. Los valores de `.env.example` sirven tal cual para desarrollo local.

Esto deja arriba una base de datos por servicio, Kafka, Redis y Vault. Al arrancar, Vault carga los secretos de cada servicio y escribe en `infra/.secrets/` las credenciales con las que cada uno inicia sesión. Ni `.env` ni `.secrets` se suben al repositorio.

## 3. Levantar los servicios

Elige una de las dos formas. Usan los mismos puertos, así que no se pueden mezclar.

### Opción A: todo en contenedores

Primero construye el jar de cada servicio. Las pruebas usan Docker, por eso debe estar encendido.

```bash
cd ..
for service in discovery-server config-server api-gateway auth-service customer-service \
               product-service account-service credit-service transaction-service \
               card-service yanki-service; do
  (cd $service && ./mvnw clean verify) || break
done
```

Construir todo con pruebas tarda varios minutos por servicio. Si solo quieres las imágenes, agrega `-DskipTests`.

En Windows usa `mvnw.cmd` desde PowerShell o `./mvnw` desde Git Bash. En Linux y macOS, si `./mvnw` responde «permission denied», ejecuta `chmod +x mvnw` en ese servicio.

Luego construye las imágenes y arranca:

```bash
cd infra
docker compose --profile apps up -d --build --wait
```

Los servicios tardan cerca de un minuto en quedar registrados después de que el comando termina.

### Opción B: desde IntelliJ IDEA

Abre la carpeta que contiene los trece repositorios. Cada servicio trae su configuración de ejecución en `.run/`, con el perfil correcto. Arráncalos en este orden:

1. `discovery-server (dev)`
2. `config-server (native)`
3. `auth-service (dev)` y `api-gateway (dev)`
4. El resto, en cualquier orden: `customer-service`, `product-service`, `account-service`, `credit-service`, `transaction-service`, `card-service` y `yanki-service`, todos con `(dev)`.

Sin IDE, el equivalente es `./mvnw spring-boot:run -Dspring-boot.run.profiles=dev` dentro de cada servicio (`native` para `config-server`).

## 4. Comprobar que funciona

En http://localhost:8761 deben aparecer registrados los diez servicios (todos menos el propio `discovery-server`).

Todas las llamadas van por el gateway y necesitan un token. El usuario inicial es `admin` y su contraseña es el valor de `AUTH_ADMIN_PASSWORD` en `.env`:

```bash
curl -s -X POST http://localhost:8080/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"<AUTH_ADMIN_PASSWORD>"}'
```

La respuesta trae `accessToken`. Con él se llama al resto:

```bash
curl -s http://localhost:8080/api/v1/products -H "Authorization: Bearer <accessToken>"
```

## 5. Probar las reglas de negocio con Postman

Importa `postman/banking-business-rules.postman_collection.json`. Tiene una carpeta por dominio y, dentro, una por regla de negocio, con el caso válido, los errores y un ejemplo guardado de cada respuesta. Inicia sesión sola y crea datos nuevos en cada corrida.

Con el Postman CLI:

```bash
postman collection run postman/banking-business-rules.postman_collection.json
```

Cada servicio tiene además su propia colección en la carpeta `postman/` de su repositorio.

### Reglas de mora

La carpeta «Mora con el reloj adelantado» se salta sola en una corrida normal, porque necesita créditos vencidos. Para probarla, adelanta 40 días el reloj de `credit-service` y pon en `true` la variable `cre_clockOffsetActive` de la colección:

```bash
CREDIT_CLOCK_OFFSET=40d docker compose --profile apps up -d credit-service
```

Desde el IDE, agrega la variable de entorno `CREDIT_CLOCK_OFFSET=40d` a la configuración de `credit-service`. Para volver a la fecha real, arranca el servicio otra vez sin esa variable.

## Direcciones

| Qué | Dirección |
|---|---|
| API Gateway (entrada de todas las APIs) | http://localhost:8080 |
| Eureka | http://localhost:8761 |
| Config Server | http://localhost:8888 |
| Vault (token: `VAULT_ROOT_TOKEN` de `.env`) | http://localhost:8200 |
| customer-service | http://localhost:8081 |
| account-service | http://localhost:8082 |
| credit-service | http://localhost:8083 |
| product-service | http://localhost:8084 |
| transaction-service | http://localhost:8085 |
| card-service | http://localhost:8086 |
| yanki-service | http://localhost:8087 |
| auth-service | http://localhost:8088 |

Cada servicio de negocio publica su contrato en `/swagger-ui/index.html` de su propio puerto.

## SonarQube (opcional)

```bash
docker compose --profile quality up -d sonarqube
```

Responde en http://localhost:9000 después de un par de minutos. No conviene tenerlo encendido junto con los once servicios en una máquina de 16 GB. El análisis de un servicio se lanza desde su carpeta:

```bash
./mvnw clean verify sonar:sonar -Dsonar.projectKey=<servicio> -Dsonar.projectName=<servicio> \
  -Dsonar.host.url=http://localhost:9000 -Dsonar.login=<token>
```

El token se genera en SonarQube y no se guarda en ningún repositorio.

## Apagar y limpiar

```bash
docker compose --profile apps stop      # detiene servicios e infraestructura
docker compose --profile apps down      # además quita los contenedores; los datos se conservan
docker compose --profile apps down -v   # borra también los datos de las bases
```

## Problemas frecuentes

- **Un servicio no arranca y el error menciona Vault.** Vault guarda todo en memoria: cada vez que su contenedor se reinicia emite credenciales nuevas. Reinicia los servicios después de reiniciar Vault.
- **`port is already allocated` o `Port 808x was already in use`.** Hay un servicio corriendo a la vez en el IDE y en contenedores, u otro programa usa ese puerto.
- **El gateway responde 503 justo después de arrancar.** El servicio de destino todavía no terminó de registrarse en Eureka; espera unos segundos.
- **Cambiaste una contraseña en `.env` y la base rechaza la conexión.** Las bases guardan la contraseña con la que se crearon. Recrea todo con `docker compose down -v` y vuelve a levantar.
- **`docker compose --profile apps up --build` falla al copiar el jar.** Falta construir ese servicio con `./mvnw clean verify`.
