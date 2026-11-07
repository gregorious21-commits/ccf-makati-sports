-- Members see their own payment status in the game detail ("Paid online",
-- "Bring ₱150 in cash", ...). The public registrations view hides payment
-- columns, so this returns ONLY the caller's own rows, after the usual PIN
-- check (_member_id counts wrong PINs and locks after 5).
-- Additive: no table or policy changes. Rollback: rollback_member_my_payments.sql

create or replace function public.member_my_payments(p_phone text, p_pin text)
returns table (id text, game_id text, pay_type text, paid boolean)
language plpgsql security definer
set search_path to 'public', 'extensions'
as $$
declare v_id text;
begin
  v_id := public._member_id(p_phone, p_pin);
  if v_id is null then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  return query
    select r.id, r.game_id, r.pay_type, coalesce(r.paid, false)
      from public.registrations r
     where r.player_id = v_id
       and r.status <> 'cancelled'
       and r.created_at > now() - interval '120 days';
end;
$$;
revoke all on function public.member_my_payments(text, text) from public;
grant execute on function public.member_my_payments(text, text) to anon, authenticated;
