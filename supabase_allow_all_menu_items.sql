-- 주문에 포함되는 서로 다른 메뉴 항목을 50개까지 허용합니다.
-- Supabase SQL Editor에서 이 파일 전체를 실행하세요.

create or replace function public.place_order(
  p_table_number text,
  p_customer_name text,
  p_request_note text,
  p_items jsonb,
  p_access_token text,
  p_special_drink_choice text default ''
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_prices jsonb := '{"할로윈 정식 세트":51000,"삼도천 단짠 세트":52000,"악마의 야식 세트":43000,"할로윈 ! special ! 세트":25000,"부대찌개":21000,"오뎅탕":19000,"공깃밥 / 면사리 추가":1000,"수육":24000,"지코바":23000,"더블순살치킨":22000,"훈제삼겹살":20000,"모둠감자튀김":15000,"두부김치":15000,"파인애플샤베트":9000,"콘치즈":9000,"맥주":5000,"매화수 / 청하":6000,"소주 (기타 술)":5000,"음료":2000,"라면밥 (지옥불 라면밥)":9000,"화채 (마녀의 눈알 화채)":14000}'::jsonb;
  v_descriptions jsonb := '{"할로윈 정식 세트":"부대찌개 · 수육 · 공깃밥/면사리 1개 · 에이드 1잔 (청포도·블루레몬·자몽 중 장바구니에서 선택)","삼도천 단짠 세트":"오뎅탕 · 마녀의 눈알 화채 · 훈제삼겹살","악마의 야식 세트":"지코바 · 모둠감자튀김 · 맥주","할로윈 ! special ! 세트":"지옥불 라면밥 · 마녀의 눈알 화채 · 에이드 1잔 (청포도·블루레몬·자몽 중 장바구니에서 선택)","공깃밥 / 면사리 추가":"공깃밥 또는 면사리 중 선택","라면밥 (지옥불 라면밥)":"지옥불 라면밥","화채 (마녀의 눈알 화채)":"마녀의 눈알 화채"}'::jsonb;
  v_total integer := 0;
  v_item jsonb;
  v_name text;
  v_qty integer;
  v_price integer;
  v_special_qty integer := 0;
  v_ade_qty integer := 0;
  v_order_id uuid;
  v_order_number text;
  v_hash text;
  v_order public.orders%rowtype;
  v_result jsonb;
begin
  if coalesce(trim(p_table_number),'') = '' then raise exception 'TABLE_REQUIRED'; end if;
  if p_access_token is null or length(p_access_token) < 20 then raise exception 'INVALID_TOKEN'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'EMPTY_ORDER'; end if;
  if jsonb_array_length(p_items) > 50 then raise exception 'TOO_MANY_ITEMS'; end if;
  v_hash := encode(extensions.digest(p_access_token, 'sha256'), 'hex');
  select * into v_order from public.orders where access_token_hash = v_hash;
  if found then
    select coalesce(jsonb_agg(jsonb_build_object('name', item_name, 'quantity', quantity, 'unit_price', unit_price, 'description', item_description)), '[]'::jsonb)
      into v_result from public.order_items where order_id = v_order.id;
    return jsonb_build_object('id',v_order.id,'order_number',v_order.order_number,'created_at',v_order.created_at,'table_number',v_order.table_number,'customer_name',v_order.customer_name,'request_note',v_order.request_note,'special_drink_choice',v_order.special_drink_choice,'total_amount',v_order.total_amount,'payment_status',v_order.payment_status,'cooking_status',v_order.cooking_status,'items',v_result);
  end if;
  for v_item in select value from jsonb_array_elements(p_items) loop
    v_name := v_item->>'name';
    if not (v_prices ? v_name) then raise exception 'INVALID_MENU_ITEM'; end if;
    if (v_item->>'quantity') !~ '^[0-9]+$' then raise exception 'INVALID_QUANTITY'; end if;
    v_qty := (v_item->>'quantity')::integer;
    if v_qty < 1 or v_qty > 99 then raise exception 'INVALID_QUANTITY'; end if;
    v_price := (v_prices->>v_name)::integer;
    v_total := v_total + v_price * v_qty;
    if v_name = '할로윈 ! special ! 세트' then v_special_qty := v_special_qty + v_qty; end if;
    if v_name in ('할로윈 정식 세트','할로윈 ! special ! 세트') then v_ade_qty := v_ade_qty + v_qty; end if;
  end loop;
  if v_ade_qty > 0 and coalesce(trim(p_special_drink_choice),'') not in ('좀비 백신 에이드 (청포도)','드라큘라 수혈 에이드 (자몽)','블루문 에이드 (영혼 포션 · 블루레몬)') then
    raise exception 'SET_ADE_REQUIRED';
  end if;
  if v_special_qty > 0 then
    update public.menu_inventory
      set quantity_sold = quantity_sold + v_special_qty, updated_at = now()
      where item_name = '할로윈 ! special ! 세트'
        and quantity_sold + v_special_qty <= quantity_limit;
    if not found then raise exception 'HALLOWEEN_SPECIAL_SOLD_OUT'; end if;
  end if;
  v_order_number := 'P-' || to_char(now() at time zone 'Asia/Seoul','YYMMDD') || '-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,6));
  insert into public.orders(order_number, access_token_hash, table_number, customer_name, request_note, special_drink_choice, total_amount)
    values(v_order_number,v_hash,trim(p_table_number),left(coalesce(trim(p_customer_name),''),30),left(coalesce(trim(p_request_note),''),300),coalesce(trim(p_special_drink_choice),''),v_total)
    returning id into v_order_id;
  for v_item in select value from jsonb_array_elements(p_items) loop
    v_name := v_item->>'name'; v_qty := (v_item->>'quantity')::integer; v_price := (v_prices->>v_name)::integer;
    insert into public.order_items(order_id,item_name,quantity,unit_price,item_description) values(v_order_id,v_name,v_qty,v_price,coalesce(v_descriptions->>v_name,''));
  end loop;
  select * into v_order from public.orders where id=v_order_id;
  select coalesce(jsonb_agg(jsonb_build_object('name', item_name, 'quantity', quantity, 'unit_price', unit_price, 'description', item_description)), '[]'::jsonb)
    into v_result from public.order_items where order_id = v_order_id;
  return jsonb_build_object('id',v_order.id,'order_number',v_order.order_number,'created_at',v_order.created_at,'table_number',v_order.table_number,'customer_name',v_order.customer_name,'request_note',v_order.request_note,'special_drink_choice',v_order.special_drink_choice,'total_amount',v_order.total_amount,'payment_status',v_order.payment_status,'cooking_status',v_order.cooking_status,'items',v_result);
end;
$$;

revoke all on function public.place_order(text,text,text,jsonb,text,text) from public;
grant execute on function public.place_order(text,text,text,jsonb,text,text) to anon, authenticated;
