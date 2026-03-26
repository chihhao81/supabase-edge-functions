


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE TYPE "public"."auction_status" AS ENUM (
    'active',
    'upcoming',
    'ended',
    'closed'
);


ALTER TYPE "public"."auction_status" OWNER TO "postgres";


CREATE TYPE "public"."user_role" AS ENUM (
    'user',
    'admin'
);


ALTER TYPE "public"."user_role" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."close_expired_auctions"() RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$begin
  ----------------------------------------------------------------
  -- 1. 更新拍賣狀態
  ----------------------------------------------------------------
  update public.auctions
  set status = s.new_status
  from (
    select id,
      case
        when now() > end_time + interval '3 days'
          then 'closed'::auction_status
        when now() < start_time
          then 'upcoming'::auction_status
        when now() between start_time and end_time
          then 'active'::auction_status
        else
          'ended'::auction_status
      end as new_status
    from public.auctions
    where status != 'closed'::auction_status
  ) s
  where auctions.id = s.id
    and auctions.status != s.new_status;


  ----------------------------------------------------------------
  -- 2. 10 分鐘提醒
  ----------------------------------------------------------------
  -- insert into notifications (user_id, type, payload)
  -- select
  --   b.user_id,
  --   'ending_soon',
  --   jsonb_build_object(
  --     'auction_count', count(distinct a.id)
  --   )
  -- from public.auctions a
  -- join bids b on b.auction_id = a.id
  -- where
  --   a.end_time between now() and now() + interval '10 minutes'
  --   and a.notified_10min = false
  -- group by b.user_id;
  
  update public.auctions
  set notified_10min = true
  where
    end_time between now() and now() + interval '10 minutes'
    and notified_10min = false
	  and status = 'active';

  ----------------------------------------------------------------
  -- 3. 通知守門條件檢查
  ----------------------------------------------------------------
  if exists (
      -- Q1：有沒有已結標但尚未通知
      select 1
      from auctions
      where status = 'ended'
        and winner_notified = false
  )
  and not exists (
      -- Q2：未來 3 分鐘內還有沒有拍賣要結束
      select 1
      from auctions
      where status in ('active','upcoming')
        and end_time <= now() + interval '3 minutes'
  )
  then

    ----------------------------------------------------------------
    -- 3-1. 找出得標者並發通知
    ----------------------------------------------------------------
    with ended_auctions as (
        select *
        from auctions
        where status = 'ended'
          and winner_notified = false
    ),

    winners as (
        select distinct on (b.auction_id)
            b.auction_id,
            b.user_id,
            b.bid_amount
        from bids b
        join ended_auctions ea on ea.id = b.auction_id
        order by b.auction_id, b.bid_amount desc
    ),

    auction_info as (
        select
            w.user_id,
            w.auction_id,
            a.title,
            w.bid_amount as final_price,
            pa.bank_name,
            pa.bank_code,
            pa.account_number
        from winners w
        join auctions a on a.id = w.auction_id
        join payment_accounts pa on pa.id = a.payment_account_id
    ),

    grouped_payload as (
        select
            user_id,
            jsonb_agg(
                jsonb_build_object(
                    'auction_id', auction_id,
                    'title', title,
                    'final_price', final_price
                )
            ) as items,
            max(bank_name) as bank_name,
            max(bank_code) as bank_code,
            max(account_number) as account_number
        from auction_info
        group by user_id
    )

    insert into notifications (user_id, type, payload)
    select
        user_id,
        'win',
        jsonb_build_object(
            'items', items,
            'bank_name', bank_name,
            'bank_code', bank_code,
            'account_number', account_number
        )
    from grouped_payload;


    ----------------------------------------------------------------
    -- 4. 標記已通知
    ----------------------------------------------------------------
    update auctions
    set winner_notified = true
    where status = 'ended'
      and winner_notified = false;

  end if;

end;$$;


ALTER FUNCTION "public"."close_expired_auctions"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_auction"("p_description" "text", "p_start_price" numeric, "p_min_increment" numeric, "p_start_time" timestamp with time zone, "p_end_time" timestamp with time zone, "p_product_id" "text", "p_product_name" "text", "p_product_size" "text", "p_quantity" integer, "p_payment_account_id" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$declare
  v_status auction_status;
  v_title text;
  v_size_text text;
begin
  -- 檢查是否為 admin
  if not exists (
    select 1 from profiles
    where id = auth.uid()
      and role = 'admin'
  ) then
    raise exception 'Not authorized';
  end if;

  -- 檢查最小加價
  if p_min_increment <= 0 then
    raise exception 'Minimum increment must be greater than 0';
  end if;

  -- 檢查數量
  if p_quantity <= 0 then
    raise exception 'Quantity must be greater than 0';
  end if;

  -- 組 title
  if p_product_size = '0' then
    v_size_text := '(0.3cm以上)';
  elsif p_product_size = '1' then
    v_size_text := '(0.5cm以上)';
  elsif p_product_size = '2' then
    v_size_text := '(亞成成體)';
  elsif p_product_size = '3' then
    v_size_text := '(幼體)';
  elsif p_product_size = '4' then
    v_size_text := '(小亞成)';
  elsif p_product_size = '5' then
    v_size_text := '(0.5-1公分)';
  elsif p_product_size = '6' then
    v_size_text := '(1-1.5公分)';
  elsif p_product_size = '7' then
    v_size_text := '(1.5-2公分)';
  elsif p_product_size = '8' then
    v_size_text := '(2-2.5公分)';
  elsif p_product_size = '9' then
    v_size_text := '(3公分以上)';
  else 
    v_size_text := '';
  end if;
  v_title := p_product_name || v_size_text || ' * ' || p_quantity;

  -- 根據開始時間決定狀態
  if p_start_time > now() then
    v_status := 'upcoming';
  else
    v_status := 'active';
  end if;

  -- 紀錄操作
  perform log_action(
    'CREATE_AUCTION',
    'auctions',
    auth.uid()::text
  );

  -- 建立 auction
  insert into auctions (
    title,
    description,
    start_price,
    current_price,
    min_increment,
    status,
    start_time,
    end_time,
    created_by,
    product_id,
    product_name,
    product_size,
    quantity,
    payment_account_id
  )
  values (
    v_title,
    p_description,
    p_start_price,
    p_start_price,
    p_min_increment,
    v_status,
    p_start_time,
    p_end_time,
    auth.uid(),
    p_product_id,
    p_product_name,
    p_product_size,
    p_quantity,
    p_payment_account_id 
  );
end;$$;


ALTER FUNCTION "public"."create_auction"("p_description" "text", "p_start_price" numeric, "p_min_increment" numeric, "p_start_time" timestamp with time zone, "p_end_time" timestamp with time zone, "p_product_id" "text", "p_product_name" "text", "p_product_size" "text", "p_quantity" integer, "p_payment_account_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_order_payload"("p_user_id" "uuid") RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$declare
  v_customer_id text;
  v_time_item text;
  v_shipping_fee int := 0;
  v_payment_account_id text;
  v_item_strings text;
  v_payload text;
begin

  -- 取得 customer_id
  select customer_id
  into v_customer_id
  from profiles
  where id = p_user_id;

  -- 批次時間
  v_time_item :=
    to_char(now(), 'MM/DD') || ' 競標';

  /*
    winners CTE：
    先用 distinct on 抓每個 auction 的最高出價者
    效能比 max 子查詢好
  */
  with winners as (
    select distinct on (b.auction_id)
      b.auction_id,
      b.user_id,
      b.bid_amount
    from bids b
    order by b.auction_id, b.bid_amount desc
  ),
  user_wins as (
    select
      a.product_name,
      a.product_size,
      a.quantity,
      a.payment_account_id,
      w.bid_amount
    from auctions a
    join winners w on w.auction_id = a.id
    where
      a.status = 'ended'
      and a.order_payload is null
      and w.user_id = p_user_id
  )

  select
    string_agg(
      product_name || ',' ||
      product_size || ',' ||
      bid_amount || ',' ||
      quantity || ',0',
      ';'
    ),
    (
      array_agg(payment_account_id order by random())
    )[1]
  into
    v_item_strings,
    v_payment_account_id
  from user_wins;

  -- 沒得標
  if v_item_strings is null then
    return null;
  end if;

  -- 組 payload
  v_payload :=
    'v2|' ||
    v_customer_id || '|' ||
    v_time_item || '|' ||
    v_shipping_fee || '|' ||
    v_payment_account_id || '|' ||
    v_item_strings;

  return v_payload;

end;$$;


ALTER FUNCTION "public"."generate_order_payload"("p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  insert into public.profiles (id)
  values (new.id);
  return new;
end;
$$;


ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."log_action"("p_action" "text", "p_target_table" "text", "p_target_id" "text") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
begin
  insert into audit_logs (
    action,
    target_table,
    target_id
  )
  values (
    p_action,
    p_target_table,
    p_target_id
  );
end;
$$;


ALTER FUNCTION "public"."log_action"("p_action" "text", "p_target_table" "text", "p_target_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notify_outbid"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$declare
  prev_bid record;
  auction_title text;
begin

  select title
  into auction_title
  from auctions
  where id = new.auction_id;

  select *
  into prev_bid
  from bids
  where auction_id = new.auction_id
  order by bid_amount desc
  offset 1
  limit 1;

  if prev_bid.user_id is not null then

    insert into notifications (
      user_id,
      type,
      payload
    )
    values (
      prev_bid.user_id,
      'outbid',
      jsonb_build_object(
        'auction_id', new.auction_id,
        'auction_title', auction_title,
        'bid_amount', new.bid_amount
      )
    );

  end if;

  return new;

end;$$;


ALTER FUNCTION "public"."notify_outbid"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notify_winner"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$declare
  winner record;
begin

  if new.status = 'ended' then

    select *
    into winner
    from bids
    where auction_id = new.id
    order by bid_amount desc
    limit 1;

    if winner.user_id is not null then

      insert into notifications (
        user_id,
        type,
        payload
      )
      values (
        winner.user_id,
        'win',
        jsonb_build_object(
          'auction_id', new.id,
          'auction_title', new.title,
          'final_price', winner.bid_amount
        )
      );

    end if;

  end if;

  return new;

end;$$;


ALTER FUNCTION "public"."notify_winner"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."place_bid"("p_auction_id" "uuid", "p_amount" numeric) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$declare
  v_current_price numeric;
  v_min_increment numeric;
  v_end_time timestamptz;
  v_last_bidder uuid;
begin

  -- 鎖住 auction row
  select current_price, min_increment, end_time
  into v_current_price, v_min_increment, v_end_time
  from auctions
  where id = p_auction_id
  for update;

  if not found then
    raise exception '競標不存在';
  end if;

  perform log_action(
    'PLACE_BID',
    'auctions',
    p_auction_id::text
  );

  -- 檢查是否仍在競標
  if v_end_time <= now() then
    raise exception '競標已結束';
  end if;

  -- 確認使用者已驗證
  if not exists (
    select 1 from profiles
    where id = auth.uid()
    and is_verified = true
    and is_banned = false
  ) then
    raise exception '使用者尚未完成驗證';
  end if;

  -- 取得目前最高出價人
  select user_id
  into v_last_bidder
  from bids
  where auction_id = p_auction_id
  order by bid_amount desc
  limit 1;

  -- 防止自己連續出價
  if v_last_bidder = auth.uid() then
    raise exception '您已經是最高出價者';
  end if;

  -- 檢查價格
  if p_amount <= v_current_price then
    raise exception '出價需高於目前價格';
  end if;

  -- 檢查加價最小幅度
  if p_amount < v_current_price + v_min_increment then
    raise exception '加價金額不足';
  end if;

  -- 檢查單次加價上限
  if p_amount - v_current_price > 5000 then
    raise exception '單次加價不可超過 5000';
  end if;

  -- 插入出價紀錄
  insert into bids (
    auction_id,
    user_id,
    bid_amount
  )
  values (
    p_auction_id,
    auth.uid(),
    p_amount
  );

  -- 更新目前價格
  update auctions
  set current_price = p_amount
  where id = p_auction_id;

  -- 壓秒延長 2 分鐘
  if v_end_time - now() <= interval '1 minutes' then
    update auctions
    set end_time = greatest(end_time, now()) + interval '2 minutes'
    where id = p_auction_id;
  end if;

end;$$;


ALTER FUNCTION "public"."place_bid"("p_auction_id" "uuid", "p_amount" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."process_notifications"() RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$declare
  r record;
begin

  for r in
    select n.*, p.line_user_id
    from notifications n
    join profiles p
    on p.id = n.user_id
    where n.is_sent = false
  loop

    perform
      net.http_post(
        url := 'https://amqmlbrivxqzrhpfppbk.supabase.co/functions/v1/send-notification',
        headers := jsonb_build_object(
          'Content-Type','application/json',
          'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFtcW1sYnJpdnhxenJocGZwcGJrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzM3MzIxNDIsImV4cCI6MjA4OTMwODE0Mn0.3GlJlQ5xZ640Sv9PZj_5yX9ucKjbI4XsKZ1pBA7X2NQ'
        ),
        body := jsonb_build_object(
          'lineUserId', r.line_user_id,
          'type', r.type,
          'payload', r.payload
        )
      );

    update notifications
    set is_sent = true
    where id = r.id
    and is_sent = false;

  end loop;

end;$$;


ALTER FUNCTION "public"."process_notifications"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rls_auto_enable"() RETURNS "event_trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog'
    AS $$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."rls_auto_enable"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trigger_process_notifications"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin

  perform process_notifications();

  return NEW;

end;
$$;


ALTER FUNCTION "public"."trigger_process_notifications"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."verify_user"("p_user_id" "uuid", "p_customer_id" "text", "p_line_group_display_name" "text", "p_phone" "text") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$begin

  update profiles
  set
    is_verified = true,
    customer_id = p_customer_id,
    phone = p_phone,
    line_group_display_name = p_line_group_display_name
  where id = p_user_id;

end;$$;


ALTER FUNCTION "public"."verify_user"("p_user_id" "uuid", "p_customer_id" "text", "p_line_group_display_name" "text", "p_phone" "text") OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."api_message_logs" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "event" "text",
    "type" "text",
    "status" integer,
    "error" "text",
    "payload" "jsonb",
    "raw_response" "jsonb",
    "line_user_id" "text"
);


ALTER TABLE "public"."api_message_logs" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."api_message_logs_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."api_message_logs_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."api_message_logs_id_seq" OWNED BY "public"."api_message_logs"."id";



CREATE TABLE IF NOT EXISTS "public"."bids" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "auction_id" "uuid",
    "user_id" "uuid",
    "bid_amount" numeric NOT NULL,
    "created_at" timestamp without time zone DEFAULT "now"()
);

ALTER TABLE ONLY "public"."bids" REPLICA IDENTITY FULL;


ALTER TABLE "public"."bids" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" NOT NULL,
    "phone" "text",
    "is_verified" boolean DEFAULT false,
    "created_at" timestamp without time zone DEFAULT "now"(),
    "role" "public"."user_role" DEFAULT 'user'::"public"."user_role",
    "line_display_name" "text",
    "line_group_display_name" "text",
    "is_banned" boolean DEFAULT false,
    "line_user_id" "text",
    "customer_id" "text",
    "picture_url" "text"
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."auction_bids_detail" WITH ("security_invoker"='true') AS
 SELECT "b"."auction_id",
    "b"."id" AS "bid_id",
    "b"."user_id",
    "b"."bid_amount",
    "b"."created_at",
    "p"."line_group_display_name" AS "bidder_name"
   FROM ("public"."bids" "b"
     JOIN "public"."profiles" "p" ON (("p"."id" = "b"."user_id")));


ALTER VIEW "public"."auction_bids_detail" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."auction_images" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "auction_id" "uuid",
    "image_url" "text",
    "created_at" timestamp without time zone DEFAULT "now"()
);


ALTER TABLE "public"."auction_images" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."auctions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "title" "text" NOT NULL,
    "description" "text",
    "start_price" numeric NOT NULL,
    "current_price" numeric NOT NULL,
    "min_increment" numeric NOT NULL,
    "start_time" timestamp without time zone DEFAULT "now"() NOT NULL,
    "end_time" timestamp without time zone NOT NULL,
    "status" "public"."auction_status" DEFAULT 'upcoming'::"public"."auction_status",
    "created_by" "uuid",
    "created_at" timestamp without time zone DEFAULT "now"(),
    "product_id" "text",
    "notified_10min" boolean DEFAULT false,
    "order_payload" "text",
    "product_name" "text",
    "product_size" "text",
    "quantity" integer,
    "payment_account_id" "text",
    "winner_notified" boolean DEFAULT false,
    CONSTRAINT "auctions_quantity_check" CHECK (("quantity" > 0))
);


ALTER TABLE "public"."auctions" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."auctions_with_top_bids" AS
SELECT
    NULL::"uuid" AS "id",
    NULL::"text" AS "title",
    NULL::"text" AS "description",
    NULL::numeric AS "start_price",
    NULL::numeric AS "current_price",
    NULL::numeric AS "min_increment",
    NULL::timestamp without time zone AS "start_time",
    NULL::timestamp without time zone AS "end_time",
    NULL::"public"."auction_status" AS "status",
    NULL::"uuid" AS "created_by",
    NULL::timestamp without time zone AS "created_at",
    NULL::"text" AS "product_id",
    NULL::boolean AS "notified_10min",
    NULL::"text" AS "order_payload",
    NULL::"text" AS "product_name",
    NULL::"text" AS "product_size",
    NULL::integer AS "quantity",
    NULL::"text" AS "payment_account_id",
    NULL::boolean AS "winner_notified",
    NULL::bigint AS "bid_count",
    NULL::numeric AS "highest_bid",
    NULL::"uuid" AS "top_bidder_id",
    NULL::"jsonb" AS "top_bids";


ALTER VIEW "public"."auctions_with_top_bids" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."audit_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid",
    "action" "text",
    "target_table" "text",
    "target_id" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."audit_logs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."notifications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "type" "text" NOT NULL,
    "payload" "jsonb" NOT NULL,
    "is_sent" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."notifications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."payment_accounts" (
    "id" "text" NOT NULL,
    "label" "text" NOT NULL,
    "bank_name" "text" NOT NULL,
    "bank_code" "text" NOT NULL,
    "account_number" "text" NOT NULL,
    "is_active" boolean DEFAULT true
);


ALTER TABLE "public"."payment_accounts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."winner" (
    "id" "uuid",
    "auction_id" "uuid",
    "user_id" "uuid",
    "bid_amount" numeric,
    "created_at" timestamp without time zone
);


ALTER TABLE "public"."winner" OWNER TO "postgres";


ALTER TABLE ONLY "public"."api_message_logs" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."api_message_logs_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."api_message_logs"
    ADD CONSTRAINT "api_message_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."auction_images"
    ADD CONSTRAINT "auction_images_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."auctions"
    ADD CONSTRAINT "auctions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."audit_logs"
    ADD CONSTRAINT "audit_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bids"
    ADD CONSTRAINT "bids_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."payment_accounts"
    ADD CONSTRAINT "payment_accounts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_line_group_display_name_unique" UNIQUE ("line_group_display_name");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_line_user_id_unique" UNIQUE ("line_user_id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



CREATE INDEX "auctions_active_end_time_idx" ON "public"."auctions" USING "btree" ("end_time") WHERE (("status" = 'active'::"public"."auction_status") AND ("notified_10min" = false));



CREATE INDEX "auctions_status_notified_idx" ON "public"."auctions" USING "btree" ("status", "winner_notified", "notified_10min");



CREATE INDEX "auctions_status_time_idx" ON "public"."auctions" USING "btree" ("status", "end_time", "start_time");



CREATE INDEX "bids_auction_id_amount_idx" ON "public"."bids" USING "btree" ("auction_id", "bid_amount" DESC, "user_id");



CREATE INDEX "bids_auction_rank_idx" ON "public"."bids" USING "btree" ("auction_id", "bid_amount" DESC, "created_at" DESC);



CREATE INDEX "idx_profiles_line_user" ON "public"."profiles" USING "btree" ("line_user_id");



CREATE INDEX "notifications_user_id_idx" ON "public"."notifications" USING "btree" ("user_id", "created_at" DESC);



CREATE OR REPLACE VIEW "public"."auctions_with_top_bids" WITH ("security_invoker"='true') AS
 WITH "ranked_bids" AS (
         SELECT "b"."auction_id",
            "b"."user_id",
            "b"."bid_amount",
            "b"."created_at",
            "p"."line_group_display_name" AS "bidder_name",
            "row_number"() OVER (PARTITION BY "b"."auction_id" ORDER BY "b"."bid_amount" DESC, "b"."created_at" DESC) AS "rn"
           FROM ("public"."bids" "b"
             JOIN "public"."profiles" "p" ON (("p"."id" = "b"."user_id")))
        ), "bid_stats" AS (
         SELECT "bids"."auction_id",
            "count"(*) AS "bid_count",
            "max"("bids"."bid_amount") AS "highest_bid"
           FROM "public"."bids"
          GROUP BY "bids"."auction_id"
        )
 SELECT "a"."id",
    "a"."title",
    "a"."description",
    "a"."start_price",
    "a"."current_price",
    "a"."min_increment",
    "a"."start_time",
    "a"."end_time",
    "a"."status",
    "a"."created_by",
    "a"."created_at",
    "a"."product_id",
    "a"."notified_10min",
    "a"."order_payload",
    "a"."product_name",
    "a"."product_size",
    "a"."quantity",
    "a"."payment_account_id",
    "a"."winner_notified",
    COALESCE("bs"."bid_count", (0)::bigint) AS "bid_count",
    "bs"."highest_bid",
    ("array_agg"("rb"."user_id") FILTER (WHERE ("rb"."rn" = 1)))[1] AS "top_bidder_id",
    COALESCE("jsonb_agg"("jsonb_build_object"('bid_amount', "rb"."bid_amount", 'bidder_name', "rb"."bidder_name", 'created_at', "rb"."created_at") ORDER BY "rb"."bid_amount" DESC, "rb"."created_at" DESC) FILTER (WHERE ("rb"."rn" <= 3)), '[]'::"jsonb") AS "top_bids"
   FROM (("public"."auctions" "a"
     LEFT JOIN "bid_stats" "bs" ON (("bs"."auction_id" = "a"."id")))
     LEFT JOIN "ranked_bids" "rb" ON (("rb"."auction_id" = "a"."id")))
  WHERE ("a"."status" <> 'closed'::"public"."auction_status")
  GROUP BY "a"."id", "bs"."bid_count", "bs"."highest_bid";



CREATE OR REPLACE TRIGGER "trigger_notify_outbid" AFTER INSERT ON "public"."bids" FOR EACH ROW EXECUTE FUNCTION "public"."notify_outbid"();

ALTER TABLE "public"."bids" DISABLE TRIGGER "trigger_notify_outbid";



CREATE OR REPLACE TRIGGER "trigger_notify_winner" AFTER UPDATE ON "public"."auctions" FOR EACH ROW WHEN (("new"."status" = 'ended'::"public"."auction_status")) EXECUTE FUNCTION "public"."notify_winner"();

ALTER TABLE "public"."auctions" DISABLE TRIGGER "trigger_notify_winner";



CREATE OR REPLACE TRIGGER "trigger_send_notifications" AFTER INSERT ON "public"."notifications" FOR EACH STATEMENT EXECUTE FUNCTION "public"."trigger_process_notifications"();



ALTER TABLE ONLY "public"."auction_images"
    ADD CONSTRAINT "auction_images_auction_id_fkey" FOREIGN KEY ("auction_id") REFERENCES "public"."auctions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."auctions"
    ADD CONSTRAINT "auctions_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."auctions"
    ADD CONSTRAINT "auctions_payment_account_id_fkey" FOREIGN KEY ("payment_account_id") REFERENCES "public"."payment_accounts"("id");



ALTER TABLE ONLY "public"."bids"
    ADD CONSTRAINT "bids_auction_id_fkey" FOREIGN KEY ("auction_id") REFERENCES "public"."auctions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."bids"
    ADD CONSTRAINT "bids_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



CREATE POLICY "Admin can create auctions" ON "public"."auctions" FOR INSERT WITH CHECK ((("auth"."uid"() = "created_by") AND (EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'admin'::"public"."user_role"))))));



CREATE POLICY "Admin can upload images" ON "public"."auction_images" FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'admin'::"public"."user_role")))));



CREATE POLICY "Anyone can read bids" ON "public"."bids" FOR SELECT USING (true);



CREATE POLICY "Public can read auction images" ON "public"."auction_images" FOR SELECT USING (true);



CREATE POLICY "Public can read visible auctions" ON "public"."auctions" FOR SELECT USING ((("status" <> 'closed'::"public"."auction_status") AND (("status" <> 'ended'::"public"."auction_status") OR (EXISTS ( SELECT 1
   FROM "public"."bids"
  WHERE (("bids"."auction_id" = "auctions"."id") AND ("bids"."user_id" = "auth"."uid"())))) OR (EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'admin'::"public"."user_role")))))));



CREATE POLICY "Users update own or Admins update all" ON "public"."profiles" FOR UPDATE USING ((("auth"."uid"() = "id") OR (( SELECT "profiles_1"."role"
   FROM "public"."profiles" "profiles_1"
  WHERE ("profiles_1"."id" = "auth"."uid"())) = 'admin'::"public"."user_role")));



CREATE POLICY "Verified users can bid" ON "public"."bids" FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."is_verified" = true) AND ("profiles"."is_banned" = false)))));



CREATE POLICY "admin only payment accounts" ON "public"."payment_accounts" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'admin'::"public"."user_role")))));



ALTER TABLE "public"."api_message_logs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."auction_images" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."auctions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."audit_logs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."bids" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."notifications" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."payment_accounts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "public profile read" ON "public"."profiles" FOR SELECT USING (true);



ALTER TABLE "public"."winner" ENABLE ROW LEVEL SECURITY;


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



GRANT ALL ON FUNCTION "public"."close_expired_auctions"() TO "anon";
GRANT ALL ON FUNCTION "public"."close_expired_auctions"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."close_expired_auctions"() TO "service_role";



GRANT ALL ON FUNCTION "public"."create_auction"("p_description" "text", "p_start_price" numeric, "p_min_increment" numeric, "p_start_time" timestamp with time zone, "p_end_time" timestamp with time zone, "p_product_id" "text", "p_product_name" "text", "p_product_size" "text", "p_quantity" integer, "p_payment_account_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_auction"("p_description" "text", "p_start_price" numeric, "p_min_increment" numeric, "p_start_time" timestamp with time zone, "p_end_time" timestamp with time zone, "p_product_id" "text", "p_product_name" "text", "p_product_size" "text", "p_quantity" integer, "p_payment_account_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_auction"("p_description" "text", "p_start_price" numeric, "p_min_increment" numeric, "p_start_time" timestamp with time zone, "p_end_time" timestamp with time zone, "p_product_id" "text", "p_product_name" "text", "p_product_size" "text", "p_quantity" integer, "p_payment_account_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."generate_order_payload"("p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."generate_order_payload"("p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_order_payload"("p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";



GRANT ALL ON FUNCTION "public"."log_action"("p_action" "text", "p_target_table" "text", "p_target_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."log_action"("p_action" "text", "p_target_table" "text", "p_target_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."log_action"("p_action" "text", "p_target_table" "text", "p_target_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."notify_outbid"() TO "anon";
GRANT ALL ON FUNCTION "public"."notify_outbid"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."notify_outbid"() TO "service_role";



GRANT ALL ON FUNCTION "public"."notify_winner"() TO "anon";
GRANT ALL ON FUNCTION "public"."notify_winner"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."notify_winner"() TO "service_role";



GRANT ALL ON FUNCTION "public"."place_bid"("p_auction_id" "uuid", "p_amount" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."place_bid"("p_auction_id" "uuid", "p_amount" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."place_bid"("p_auction_id" "uuid", "p_amount" numeric) TO "service_role";



GRANT ALL ON FUNCTION "public"."process_notifications"() TO "anon";
GRANT ALL ON FUNCTION "public"."process_notifications"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."process_notifications"() TO "service_role";



GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "anon";
GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trigger_process_notifications"() TO "anon";
GRANT ALL ON FUNCTION "public"."trigger_process_notifications"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trigger_process_notifications"() TO "service_role";



GRANT ALL ON FUNCTION "public"."verify_user"("p_user_id" "uuid", "p_customer_id" "text", "p_line_group_display_name" "text", "p_phone" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."verify_user"("p_user_id" "uuid", "p_customer_id" "text", "p_line_group_display_name" "text", "p_phone" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."verify_user"("p_user_id" "uuid", "p_customer_id" "text", "p_line_group_display_name" "text", "p_phone" "text") TO "service_role";



GRANT ALL ON TABLE "public"."api_message_logs" TO "anon";
GRANT ALL ON TABLE "public"."api_message_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."api_message_logs" TO "service_role";



GRANT ALL ON SEQUENCE "public"."api_message_logs_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."api_message_logs_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."api_message_logs_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."bids" TO "anon";
GRANT ALL ON TABLE "public"."bids" TO "authenticated";
GRANT ALL ON TABLE "public"."bids" TO "service_role";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE "public"."auction_bids_detail" TO "anon";
GRANT ALL ON TABLE "public"."auction_bids_detail" TO "authenticated";
GRANT ALL ON TABLE "public"."auction_bids_detail" TO "service_role";



GRANT ALL ON TABLE "public"."auction_images" TO "anon";
GRANT ALL ON TABLE "public"."auction_images" TO "authenticated";
GRANT ALL ON TABLE "public"."auction_images" TO "service_role";



GRANT ALL ON TABLE "public"."auctions" TO "anon";
GRANT ALL ON TABLE "public"."auctions" TO "authenticated";
GRANT ALL ON TABLE "public"."auctions" TO "service_role";



GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE "public"."auctions_with_top_bids" TO "anon";
GRANT ALL ON TABLE "public"."auctions_with_top_bids" TO "authenticated";
GRANT ALL ON TABLE "public"."auctions_with_top_bids" TO "service_role";



GRANT ALL ON TABLE "public"."audit_logs" TO "anon";
GRANT ALL ON TABLE "public"."audit_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."audit_logs" TO "service_role";



GRANT ALL ON TABLE "public"."notifications" TO "anon";
GRANT ALL ON TABLE "public"."notifications" TO "authenticated";
GRANT ALL ON TABLE "public"."notifications" TO "service_role";



GRANT ALL ON TABLE "public"."payment_accounts" TO "anon";
GRANT ALL ON TABLE "public"."payment_accounts" TO "authenticated";
GRANT ALL ON TABLE "public"."payment_accounts" TO "service_role";



GRANT ALL ON TABLE "public"."winner" TO "anon";
GRANT ALL ON TABLE "public"."winner" TO "authenticated";
GRANT ALL ON TABLE "public"."winner" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";







