# AGENTS.md - Руководство для AI-агентов

Этот документ содержит информацию о проекте s3w для AI-агентов, работающих с этой кодовой базой.

## Описание проекта

s3w - это простой S3-прокси сервер на Haskell, который предоставляет HTTP API для работы с S3-совместимыми хранилищами (например, MinIO). Проект использует Warp/WAI для HTTP-сервера, Minio-hs для работы с S3 API и co-log-json для структурированного логирования.

## Сборка и запуск

### Команды сборки

```bash
# Сборка проекта (требуется Nix)
nix-build

# Запуск REPL для разработки
cabal repl

# Запуск ghcid для авто-пересборки при изменениях
ghcid

# Сборка Docker-образа
VERSION=x.x.x ./build.sh
```

### Зависимости

Проект использует Nix для управления зависимостями. Основные компоненты:
- GHC 9.4
- Cabal 3.x
- ghcid (для разработки)
- Nixpkgs (версия указана в nixpkgs.json)

### Переменные окружения

Для запуска приложения требуются:
- `S3W_PORT` - порт HTTP-сервера
- `S3_REGION` - регион S3
- `S3_CONN_STR` - строка подключения к S3
- `AWS_ACCESS_KEY_ID` - ключ доступа S3
- `AWS_SECRET_ACCESS_KEY` - секретный ключ S3
- `S3W_MIN_LOG` (опционально) - минимальный уровень логирования (Debug/Info/Err)

### Запуск

```bash
# Сборка и запуск
nix-build && ./result/bin/s3w

# Проверка версии
./result/bin/s3w --version
```

## Тестирование

В проекте **нет тестов** на данный момент.

## Линтинг и проверка кода

Проект использует GHC с флагами `-Wall -Werror -O2`, что означает:
- Все предупреждения компилятора считаются ошибками
- Код должен компилироваться без предупреждений
- Оптимизация уровня O2 включена по умолчанию

Проверка выполняется автоматически при сборке через `cabal build` или `nix-build`.

## Стиль кода

### Языковые расширения

Проект использует GHC2021 как базовый язык. Дополнительные расширения, включенные глобально:

```haskell
LambdaCase           -- Сопоставление с образцом в lambda
ViewPatterns         -- View patterns в pattern matching
OverloadedStrings    -- Строковые литералы полиморфны
BlockArguments       -- Блоки как аргументы без скобок
PartialTypeSignatures -- Частичные сигнатуры типов
```

Дополнительные расширения в отдельных модулях:
```haskell
PatternSynonyms      -- Пользовательские pattern synonyms
RecordWildCards      -- Распаковка полей записи
ImpredicativeTypes   -- Импредикативная полиморфность
```

### Импорты

**Правила организации импортов:**

1. Импорты Prelude:
```haskell
import Prelude hiding (log)
```

2. Стандартные библиотеки (неквалифицированные):
```haskell
import Control.Exception
import Control.Monad
import Control.Concurrent
import Data.Text as T
import Data.Text.Encoding as TE
import Data.String
import Data.ByteString as B
```

3. Квалифицированные импорты для избежания конфликтов:
```haskell
import qualified System.Environment as Env
import qualified UnliftIO.Exception as U
import qualified UnliftIO.MVar as U
import qualified Data.List as L
import qualified Network.URI.Encode as URI.Encode
```

4. Импорты из проекта:
```haskell
import Paths_s3w (version)
import Colog.Json
import Colog.Json.Action
```

### Форматирование кода

**Общие принципы:**

1. **Сигнатуры типов:** Всегда указывайте сигнатуры функций на верхнем уровне
```haskell
consumeMinioResult
  :: Logger
  -> IO b
  -> IO b
  -> (a -> IO b)
  -> MinioResult a
  -> IO b
```

2. **Где-clauses и let-in:** Используйте `where` для вспомогательных функций, `let` для локальных значений

3. **Блочные аргументы:** Используйте BlockArguments для lambda и case:
```haskell
-- Предпочтительно
runMinioApp \f -> do
  try (runMinioWith conn (f conn)) <&> \case
    Left e -> MinioException e
    Right (Left me) -> MinioError me
    Right (Right s) -> MinioSuccess s

-- Вместо
runMinioApp (\f -> do
  try (runMinioWith conn (f conn)) <&> (\case
    Left e -> MinioException e
    Right (Left me) -> MinioError me
    Right (Right s) -> MinioSuccess s))
```

4. **LambdaCase:** Используйте для pattern matching в lambda:
```haskell
-- Предпочтительно
Env.getArgs >>= \case
  ["--version"] -> putStrLn (showVersion version)
  _ -> mainLogic

-- Вместо
Env.getArgs >>= (\x -> case x of
  ["--version"] -> putStrLn (showVersion version)
  _ -> mainLogic)
```

### Именование

**Соглашения по именованию:**

1. Типы данных: PascalCase
```haskell
data S3WErr = S3WErrCL
data MinioResult a = MinioError MinioErr | ...
data QueueHandler = QueueHandler { ... }
```

2. Функции: camelCase
```haskell
obtainS3Creds :: IO CredentialValue
mkMinioAppRunner :: IO MinioHandler
consumeMinioResult :: Logger -> ...
```

3. Конструкторы типов: PascalCase
```haskell
MinioHandler (forall a . (MinioConn -> Minio a) -> IO (MinioResult a))
```

4. Поля записей: camelCase
```haskell
data QueueHandler = QueueHandler
  { onTakingQ :: forall a . IO a -> (ByteString -> IO a) -> IO a
  , putQ :: ByteString -> IO ()
  , closeQ :: IO ()
  }
```

5. Pattern synonyms: PascalCase
```haskell
pattern KeyBucket :: Text -> Text -> [Text]
pattern KeyBucket k b <- ...
```

### Обработка ошибок

**Подходы к обработке ошибок:**

1. Используйте `MinioResult` тип для результатов операций с S3:
```haskell
data MinioResult a = 
    MinioError MinioErr
  | MinioException SomeException
  | MinioSuccess a
```

2. Используйте `consumeMinioResult` для единообразной обработки:
```haskell
consumeMinioResult log_ onExcp onErr onSucc = \case
  MinioException e -> do
    log_ Err "s3" [("exception", asCtx $ show e)] "got exception"
    onExcp
  MinioError me -> do
    log_ Err "s3" [("error", asCtx $ show me)] "got minio error"
    onErr
  MinioSuccess x -> onSucc x
```

3. Используйте `UnliftIO.Exception` для безопасной работы с исключениями:
```haskell
import qualified UnliftIO.Exception as U

U.try (getObject bucket key defaultGetObjectOptions) >>= \case
  Left (e :: SomeException) -> handleException e
  Right gor -> handleSuccess gor
```

4. Используйте `throwIO` для критических ошибок:
```haskell
Nothing -> throwIO $ errorCallException "Not found env variable"
```

### Логирование

**Используйте структурированное логирование:**

1. Базовое логирование:
```haskell
log :: LogSerevity -> Text -> [(Text, Ctx)] -> String -> IO ()
log Info "namespace" [("key", asCtx value)] "message"
```

2. Уровни логирования: Debug, Info, Err

3. Контекст логирования:
```haskell
-- Добавление времени
mkLogCurrentTime :: Logger -> Logger

-- Добавление bucket/key
mkLogBucketKey :: Text -> Text -> Logger -> Logger

-- Добавление метода
mkLogMethod :: Text -> Logger -> Logger
```

4. Преобразование в контекст:
```haskell
asCtx :: forall a . ToJSON a => a -> Ctx
```

### Конкурентность

**Правила работы с конкурентностью:**

1. Используйте `async` для фоновых задач:
```haskell
void $ async do
  log_ Info "client" [] "start getting"
  runMinioApp (const minioGet) >>= consumeMinioResult ...
  closeQ
```

2. Используйте STM для изменяемого состояния:
```haskell
minimalLogSeverity :: TVar LogSerevity
minimalLogSeverity = unsafePerformIO $ newTVarIO Info
```

3. Используйте MVar для синхронизации:
```haskell
gorObjectInfoMVar <- newEmptyMVar
takeMVar gorObjectInfoMVar >>= \case
  Left _e -> rr $ responseLBS internalServerError500 [] ""
  Right info -> handleSuccess info
```

4. Используйте UnliftIO версии примитивов синхронизации:
```haskell
import qualified UnliftIO.MVar as U
```

### Работа с Conduit

Используйте Conduit для потоковой обработки данных:
```haskell
runConduit $ gorObjectStream gor .| CC.mapM_ (liftIO . putQ)
```

## Архитектура проекта

```
s3w/
├── app/
│   └── Main.hs           # Основное приложение
├── co-log-json/          # Библиотека структурированного логирования
│   └── src/
│       ├── Colog/Json.hs
│       ├── Colog/Json/Action.hs
│       └── Colog/Json/Internal/Structured.hs
├── s3w.cabal             # Конфигурация Cabal
├── default.nix           # Конфигурация Nix для сборки
├── shell.nix             # Nix shell для разработки
└── docker.nix            # Конфигурация для Docker-образа
```

## Важные заметки

1. **Нет комментариев в коде** - код должен быть самодокументируемым
2. **-Werror** - код должен компилироваться без предупреждений
3. **Тесты отсутствуют** - будьте осторожны при рефакторинге
4. **Используйте Nix** - для воспроизводимых сборок
5. **Pattern synonyms** - активно используются для парсинга путей
6. **Оптимизации RTS** - настроены для production: `-N4 -A32m -AL64m -I0 -xn -qg`
