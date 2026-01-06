# Gourmet Express Database Schema & Seed

This database container uses PostgreSQL.

## Connection
`db_connection.txt` contains the `psql` connection command.

**Important:** The preview/runtime database port is **5001** (not 5000).

## Apply schema + seed
From the database container directory:

```bash
chmod +x apply_schema_and_seed.sh
./apply_schema_and_seed.sh
```

## Entities / Tables
- `users` (with enum `user_role`)
- `restaurants`
- `menus`
- `menu_items`
- `orders` (with enum `order_status`)
- `order_items`
- `delivery_assignments` (with enum `delivery_status`)
- `tracking_events`
- `payments` (with enum `payment_status`)

## Indexes (high level)
- Lookups by:
  - `restaurants.owner_user_id`
  - `menus.restaurant_id`
  - `menu_items.menu_id`, `menu_items.restaurant_id`
  - `orders.customer_user_id`, `orders.restaurant_id`, `orders.status`
  - `order_items.order_id`, `order_items.menu_item_id`
  - `delivery_assignments.delivery_user_id`, `delivery_assignments.status`
  - `tracking_events.order_id`, `tracking_events.created_at`
  - `payments.status`

## Seed data
The seed inserts:
- 3 users (customer, restaurant_admin, delivery_person)
- 3 restaurants in San Francisco
- 1 menu per restaurant
- a few menu items per restaurant for initial browsing/ordering
