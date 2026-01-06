#!/usr/bin/env bash
set -euo pipefail

# This script applies the Gourmet Express schema + seed data.
# It reads the base psql connection command from db_connection.txt and rewrites the port to 5001
# (preview database port) to avoid hardcoding 5000.
#
# NOTE: Designed to be idempotent:
# - CREATE TYPE uses DO blocks with pg_type checks
# - CREATE TABLE uses IF NOT EXISTS
# - CREATE INDEX uses IF NOT EXISTS
# - INSERTs use ON CONFLICT DO NOTHING

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB_CONN_FILE="${SCRIPT_DIR}/db_connection.txt"

if [[ ! -f "${DB_CONN_FILE}" ]]; then
  echo "ERROR: db_connection.txt not found at ${DB_CONN_FILE}"
  exit 1
fi

BASE_CMD="$(cat "${DB_CONN_FILE}" | tr -d '\n' | sed 's/[[:space:]]*$//')"
if [[ -z "${BASE_CMD}" ]]; then
  echo "ERROR: db_connection.txt is empty"
  exit 1
fi

# Rewrite port to 5001 (preview system). We specifically replace ':<digits>/' in the postgres URL.
# Example: postgresql://user:pass@localhost:5000/myapp -> ...:5001/myapp
PSQL_CMD="$(echo "${BASE_CMD}" | sed -E 's/:([0-9]{2,5})\\//:5001\\//')"

echo "Using connection command:"
echo "  ${PSQL_CMD}"

run_sql () {
  local sql="$1"
  # Use -v ON_ERROR_STOP=1 for fail-fast behavior.
  # Execute exactly one statement per call as a conservative pattern.
  eval "${PSQL_CMD} -v ON_ERROR_STOP=1 -c \"$sql\""
}

echo "Applying schema..."

run_sql "CREATE EXTENSION IF NOT EXISTS pgcrypto;"

# Enums
run_sql "DO \\$\\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'user_role') THEN CREATE TYPE user_role AS ENUM ('customer','restaurant_admin','delivery_person','admin'); END IF; END \\$\\$;"
run_sql "DO \\$\\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'order_status') THEN CREATE TYPE order_status AS ENUM ('pending','confirmed','preparing','ready_for_pickup','picked_up','delivered','cancelled'); END IF; END \\$\\$;"
run_sql "DO \\$\\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'payment_status') THEN CREATE TYPE payment_status AS ENUM ('pending','authorized','paid','failed','refunded'); END IF; END \\$\\$;"
run_sql "DO \\$\\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'delivery_status') THEN CREATE TYPE delivery_status AS ENUM ('unassigned','assigned','picked_up','delivered','cancelled'); END IF; END \\$\\$;"

# Tables
run_sql "CREATE TABLE IF NOT EXISTS users (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), email TEXT NOT NULL UNIQUE, password_hash TEXT, full_name TEXT, phone TEXT, role user_role NOT NULL DEFAULT 'customer', is_active BOOLEAN NOT NULL DEFAULT TRUE, created_at TIMESTAMPTZ NOT NULL DEFAULT now(), updated_at TIMESTAMPTZ NOT NULL DEFAULT now());"

run_sql "CREATE TABLE IF NOT EXISTS restaurants (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), owner_user_id UUID REFERENCES users(id) ON DELETE SET NULL, name TEXT NOT NULL, description TEXT, phone TEXT, address_line1 TEXT, address_line2 TEXT, city TEXT, state TEXT, postal_code TEXT, latitude NUMERIC(9,6), longitude NUMERIC(9,6), is_active BOOLEAN NOT NULL DEFAULT TRUE, created_at TIMESTAMPTZ NOT NULL DEFAULT now(), updated_at TIMESTAMPTZ NOT NULL DEFAULT now());"

run_sql "CREATE TABLE IF NOT EXISTS menus (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), restaurant_id UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE, name TEXT NOT NULL DEFAULT 'Main Menu', description TEXT, is_active BOOLEAN NOT NULL DEFAULT TRUE, created_at TIMESTAMPTZ NOT NULL DEFAULT now(), updated_at TIMESTAMPTZ NOT NULL DEFAULT now(), UNIQUE(restaurant_id, name));"

run_sql "CREATE TABLE IF NOT EXISTS menu_items (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), menu_id UUID NOT NULL REFERENCES menus(id) ON DELETE CASCADE, restaurant_id UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE, name TEXT NOT NULL, description TEXT, price_cents INTEGER NOT NULL CHECK (price_cents >= 0), currency TEXT NOT NULL DEFAULT 'USD', image_url TEXT, is_available BOOLEAN NOT NULL DEFAULT TRUE, created_at TIMESTAMPTZ NOT NULL DEFAULT now(), updated_at TIMESTAMPTZ NOT NULL DEFAULT now());"

run_sql "CREATE TABLE IF NOT EXISTS orders (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), customer_user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT, restaurant_id UUID NOT NULL REFERENCES restaurants(id) ON DELETE RESTRICT, status order_status NOT NULL DEFAULT 'pending', subtotal_cents INTEGER NOT NULL DEFAULT 0 CHECK (subtotal_cents >= 0), delivery_fee_cents INTEGER NOT NULL DEFAULT 0 CHECK (delivery_fee_cents >= 0), tax_cents INTEGER NOT NULL DEFAULT 0 CHECK (tax_cents >= 0), total_cents INTEGER NOT NULL DEFAULT 0 CHECK (total_cents >= 0), currency TEXT NOT NULL DEFAULT 'USD', delivery_address_line1 TEXT, delivery_address_line2 TEXT, delivery_city TEXT, delivery_state TEXT, delivery_postal_code TEXT, notes TEXT, placed_at TIMESTAMPTZ NOT NULL DEFAULT now(), updated_at TIMESTAMPTZ NOT NULL DEFAULT now());"

run_sql "CREATE TABLE IF NOT EXISTS order_items (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), order_id UUID NOT NULL REFERENCES orders(id) ON DELETE CASCADE, menu_item_id UUID NOT NULL REFERENCES menu_items(id) ON DELETE RESTRICT, name_snapshot TEXT NOT NULL, price_cents_snapshot INTEGER NOT NULL CHECK (price_cents_snapshot >= 0), quantity INTEGER NOT NULL CHECK (quantity > 0), line_total_cents INTEGER NOT NULL CHECK (line_total_cents >= 0));"

run_sql "CREATE TABLE IF NOT EXISTS delivery_assignments (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), order_id UUID NOT NULL UNIQUE REFERENCES orders(id) ON DELETE CASCADE, delivery_user_id UUID REFERENCES users(id) ON DELETE SET NULL, status delivery_status NOT NULL DEFAULT 'unassigned', assigned_at TIMESTAMPTZ, picked_up_at TIMESTAMPTZ, delivered_at TIMESTAMPTZ, updated_at TIMESTAMPTZ NOT NULL DEFAULT now());"

run_sql "CREATE TABLE IF NOT EXISTS tracking_events (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), order_id UUID NOT NULL REFERENCES orders(id) ON DELETE CASCADE, event_type TEXT NOT NULL, status order_status, message TEXT, latitude NUMERIC(9,6), longitude NUMERIC(9,6), created_at TIMESTAMPTZ NOT NULL DEFAULT now());"

run_sql "CREATE TABLE IF NOT EXISTS payments (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), order_id UUID NOT NULL UNIQUE REFERENCES orders(id) ON DELETE CASCADE, provider TEXT NOT NULL DEFAULT 'mock', provider_payment_id TEXT, status payment_status NOT NULL DEFAULT 'pending', amount_cents INTEGER NOT NULL CHECK (amount_cents >= 0), currency TEXT NOT NULL DEFAULT 'USD', created_at TIMESTAMPTZ NOT NULL DEFAULT now(), updated_at TIMESTAMPTZ NOT NULL DEFAULT now());"

# Indexes
run_sql "CREATE UNIQUE INDEX IF NOT EXISTS idx_restaurants_name_city ON restaurants(name, city);"
run_sql "CREATE INDEX IF NOT EXISTS idx_restaurants_owner_user_id ON restaurants(owner_user_id);"
run_sql "CREATE INDEX IF NOT EXISTS idx_menus_restaurant_id ON menus(restaurant_id);"
run_sql "CREATE INDEX IF NOT EXISTS idx_menu_items_menu_id ON menu_items(menu_id);"
run_sql "CREATE INDEX IF NOT EXISTS idx_menu_items_restaurant_id ON menu_items(restaurant_id);"
run_sql "CREATE INDEX IF NOT EXISTS idx_orders_customer_user_id ON orders(customer_user_id);"
run_sql "CREATE INDEX IF NOT EXISTS idx_orders_restaurant_id ON orders(restaurant_id);"
run_sql "CREATE INDEX IF NOT EXISTS idx_orders_status ON orders(status);"
run_sql "CREATE INDEX IF NOT EXISTS idx_order_items_order_id ON order_items(order_id);"
run_sql "CREATE INDEX IF NOT EXISTS idx_order_items_menu_item_id ON order_items(menu_item_id);"
run_sql "CREATE INDEX IF NOT EXISTS idx_delivery_assignments_delivery_user_id ON delivery_assignments(delivery_user_id);"
run_sql "CREATE INDEX IF NOT EXISTS idx_delivery_assignments_status ON delivery_assignments(status);"
run_sql "CREATE INDEX IF NOT EXISTS idx_tracking_events_order_id ON tracking_events(order_id);"
run_sql "CREATE INDEX IF NOT EXISTS idx_tracking_events_created_at ON tracking_events(created_at);"
run_sql "CREATE INDEX IF NOT EXISTS idx_payments_status ON payments(status);"

echo "Applying seed data..."

# Seed users
run_sql "INSERT INTO users (id, email, full_name, role) VALUES ('00000000-0000-0000-0000-000000000001','alice@example.com','Alice Customer','customer') ON CONFLICT (email) DO NOTHING;"
run_sql "INSERT INTO users (id, email, full_name, role) VALUES ('00000000-0000-0000-0000-000000000002','rachel@pasta.example','Rachel Pasta','restaurant_admin') ON CONFLICT (email) DO NOTHING;"
run_sql "INSERT INTO users (id, email, full_name, role) VALUES ('00000000-0000-0000-0000-000000000003','dan@delivery.example','Dan Driver','delivery_person') ON CONFLICT (email) DO NOTHING;"

# Seed restaurants
run_sql "INSERT INTO restaurants (id, owner_user_id, name, description, phone, address_line1, city, state, postal_code, latitude, longitude) VALUES ('10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000002','Pasta Palace','Fresh handmade pasta and classic Italian favorites.','+1-555-0101','123 Noodle St','San Francisco','CA','94105',37.789000,-122.394000) ON CONFLICT DO NOTHING;"
run_sql "INSERT INTO restaurants (id, name, description, phone, address_line1, city, state, postal_code, latitude, longitude) VALUES ('10000000-0000-0000-0000-000000000002','Sushi Sprint','Quick, high-quality sushi and bowls.','+1-555-0102','456 Ocean Ave','San Francisco','CA','94107',37.776000,-122.395000) ON CONFLICT DO NOTHING;"
run_sql "INSERT INTO restaurants (id, name, description, phone, address_line1, city, state, postal_code, latitude, longitude) VALUES ('10000000-0000-0000-0000-000000000003','Burger Boulevard','Smash burgers, fries, and shakes.','+1-555-0103','789 Grill Rd','San Francisco','CA','94103',37.773500,-122.412000) ON CONFLICT DO NOTHING;"

# Seed menus
run_sql "INSERT INTO menus (id, restaurant_id, name, description) VALUES ('20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','Main Menu','Signature pasta dishes') ON CONFLICT (restaurant_id, name) DO NOTHING;"
run_sql "INSERT INTO menus (id, restaurant_id, name, description) VALUES ('20000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000002','Main Menu','Sushi and rice bowls') ON CONFLICT (restaurant_id, name) DO NOTHING;"
run_sql "INSERT INTO menus (id, restaurant_id, name, description) VALUES ('20000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000003','Main Menu','Burgers and sides') ON CONFLICT (restaurant_id, name) DO NOTHING;"

# Seed menu items
run_sql "INSERT INTO menu_items (id, menu_id, restaurant_id, name, description, price_cents) VALUES ('30000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','Spaghetti Carbonara','Pancetta, egg, pecorino romano, black pepper.',1599) ON CONFLICT DO NOTHING;"
run_sql "INSERT INTO menu_items (id, menu_id, restaurant_id, name, description, price_cents) VALUES ('30000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','Margherita Flatbread','Tomato, basil, mozzarella on crispy flatbread.',1299) ON CONFLICT DO NOTHING;"
run_sql "INSERT INTO menu_items (id, menu_id, restaurant_id, name, description, price_cents) VALUES ('30000000-0000-0000-0000-000000000003','20000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000002','Salmon Nigiri (6 pcs)','Fresh salmon over seasoned rice.',1399) ON CONFLICT DO NOTHING;"
run_sql "INSERT INTO menu_items (id, menu_id, restaurant_id, name, description, price_cents) VALUES ('30000000-0000-0000-0000-000000000004','20000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000002','Spicy Tuna Bowl','Sushi rice, spicy tuna, cucumber, avocado.',1499) ON CONFLICT DO NOTHING;"
run_sql "INSERT INTO menu_items (id, menu_id, restaurant_id, name, description, price_cents) VALUES ('30000000-0000-0000-0000-000000000005','20000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000003','Classic Smash Burger','Two patties, cheddar, pickles, special sauce.',1199) ON CONFLICT DO NOTHING;"

echo "Done."
echo ""
echo "Schema tables created:"
echo "  users, restaurants, menus, menu_items, orders, order_items, delivery_assignments, tracking_events, payments"
echo ""
echo "Seed data inserted:"
echo "  - 3 users"
echo "  - 3 restaurants"
echo "  - 3 menus"
echo "  - 5 menu_items"
