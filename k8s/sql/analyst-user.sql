-- Run once on the primary. Replace the placeholder with the value stored in the
-- wine-db-analyst secret; never commit a real password.

CREATE USER analyst WITH PASSWORD '__SET_FROM_SECRET__';

GRANT CONNECT ON DATABASE wine_library TO analyst;
GRANT USAGE ON SCHEMA public TO analyst;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO analyst;

-- FOR ROLE wine_app is required, not optional. Default privileges attach to the
-- role that creates the object, and Flyway runs as wine_app. Without it the
-- analyst sees today's tables but not any table a later migration adds.
ALTER DEFAULT PRIVILEGES FOR ROLE wine_app IN SCHEMA public
  GRANT SELECT ON TABLES TO analyst;
