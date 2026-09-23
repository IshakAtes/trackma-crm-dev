begin;

create extension if not exists pgtap with schema extensions;
select plan(26);

insert into auth.users (id, email) values
  ('10000000-0000-0000-0000-000000000001', 'agent-a@example.test'),
  ('10000000-0000-0000-0000-000000000002', 'agent-b@example.test'),
  ('10000000-0000-0000-0000-000000000003', 'agent-c@example.test');

insert into public.profiles (id, first_name, last_name) values
  ('10000000-0000-0000-0000-000000000001', 'Agent', 'A'),
  ('10000000-0000-0000-0000-000000000002', 'Agent', 'B'),
  ('10000000-0000-0000-0000-000000000003', 'Agent', 'C');

insert into public.organizations (id, name) values
  ('20000000-0000-0000-0000-000000000001', 'Organization A'),
  ('20000000-0000-0000-0000-000000000002', 'Organization B');

insert into public.organization_members (id, organization_id, user_id, role) values
  ('30000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'agent'),
  ('30000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000002', 'agent'),
  ('30000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000003', 'agent');

insert into public.contract_types(id, organization_id, key, name) values ('a0000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','electricity','Electricity');

set local role authenticated;
set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000001';

select lives_ok(
  $$insert into public.customers (
      id, organization_id, created_by, owner_id, first_name, last_name
    ) values (
      '40000000-0000-0000-0000-000000000001',
      '20000000-0000-0000-0000-000000000001',
      '10000000-0000-0000-0000-000000000001',
      '10000000-0000-0000-0000-000000000001',
      'Customer', 'A'
    )$$,
  'A: User A can create Customer A for themselves'
);
select results_eq(
  $$select count(*) from public.customers where id = '40000000-0000-0000-0000-000000000001'$$,
  array[1::bigint],
  'A: User A can read Customer A'
);

insert into public.customers (
  id, organization_id, created_by, owner_id, first_name, last_name
) values (
  '40000000-0000-0000-0000-000000000002',
  '20000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000001',
  'Customer', 'A2'
);
insert into public.contracts (
  id, organization_id, customer_id, created_by, contract_type_id, status
) values (
  '50000000-0000-0000-0000-000000000001',
  '20000000-0000-0000-0000-000000000001',
  '40000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000001',
  'a0000000-0000-0000-0000-000000000001', 'active'
);
insert into public.follow_ups (
  id, organization_id, customer_id, contract_id, assigned_to, created_by, due_at, type, status
) values (
  '60000000-0000-0000-0000-000000000001',
  '20000000-0000-0000-0000-000000000001',
  '40000000-0000-0000-0000-000000000001',
  '50000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000001',
  '2027-01-01 09:00:00+00', 'renewal', 'not_started'
);
insert into public.notes (
  id, organization_id, customer_id, contract_id, created_by, content
) values (
  '70000000-0000-0000-0000-000000000001',
  '20000000-0000-0000-0000-000000000001',
  '40000000-0000-0000-0000-000000000001',
  '50000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000001',
  'Internal test note'
);
insert into public.referrals (
  id, organization_id, referrer_customer_id, referred_customer_id
) values (
  '80000000-0000-0000-0000-000000000001',
  '20000000-0000-0000-0000-000000000001',
  '40000000-0000-0000-0000-000000000001',
  '40000000-0000-0000-0000-000000000002'
);

set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000002';
select results_eq(
  $$select count(*) from public.customers where id = '40000000-0000-0000-0000-000000000001'$$,
  array[0::bigint],
  'B: Same-organization non-owner cannot read Customer A'
);
select results_eq(
  $$update public.customers set city = 'Changed' where id = '40000000-0000-0000-0000-000000000001' returning id$$,
  $$select id from public.customers where false$$,
  'C: Same-organization non-owner cannot update Customer A'
);
select results_eq(
  $$delete from public.customers where id = '40000000-0000-0000-0000-000000000001' returning id$$,
  $$select id from public.customers where false$$,
  'D: Same-organization non-owner cannot delete Customer A'
);

set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000003';
select results_eq(
  $$select count(*) from public.customers where id = '40000000-0000-0000-0000-000000000001'$$,
  array[0::bigint],
  'E: A user in another organization cannot read Customer A'
);

set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000002';
select results_eq(
  $$select count(*) from public.contracts where customer_id = '40000000-0000-0000-0000-000000000001'$$,
  array[0::bigint],
  'F: Unauthorized user cannot read Customer A contracts'
);
select results_eq(
  $$select count(*) from public.follow_ups where customer_id = '40000000-0000-0000-0000-000000000001'$$,
  array[0::bigint],
  'G: Unauthorized user cannot read Customer A follow-ups'
);
select results_eq(
  $$select count(*) from public.notes where customer_id = '40000000-0000-0000-0000-000000000001'$$,
  array[0::bigint],
  'H: Unauthorized user cannot read Customer A notes'
);
select results_eq(
  $$select count(*) from public.referrals where referrer_customer_id = '40000000-0000-0000-0000-000000000001'$$,
  array[0::bigint],
  'I: Unauthorized user cannot read Customer A referrals'
);
select throws_ok(
  $$insert into public.contracts (
      organization_id, customer_id, created_by, contract_type_id, status
    ) values (
      '20000000-0000-0000-0000-000000000001',
      '40000000-0000-0000-0000-000000000001',
      '10000000-0000-0000-0000-000000000002',
      'a0000000-0000-0000-0000-000000000001', 'active'
    )$$,
  '42501',
  null,
  'Unauthorized user cannot insert a contract for Customer A'
);
select throws_ok(
  $$insert into public.follow_ups (
      organization_id, customer_id, assigned_to, created_by, due_at, type, status
    ) values (
      '20000000-0000-0000-0000-000000000001',
      '40000000-0000-0000-0000-000000000001',
      '10000000-0000-0000-0000-000000000002',
      '10000000-0000-0000-0000-000000000002',
      now(), 'renewal', 'not_started'
    )$$,
  '42501',
  null,
  'Unauthorized user cannot insert a follow-up for Customer A'
);
select throws_ok(
  $$insert into public.notes (
      organization_id, customer_id, created_by, content
    ) values (
      '20000000-0000-0000-0000-000000000001',
      '40000000-0000-0000-0000-000000000001',
      '10000000-0000-0000-0000-000000000002',
      'Unauthorized note'
    )$$,
  '42501',
  null,
  'Unauthorized user cannot insert a note for Customer A'
);
select throws_ok(
  $$insert into public.referrals (
      organization_id, referrer_customer_id, referred_customer_id
    ) values (
      '20000000-0000-0000-0000-000000000001',
      '40000000-0000-0000-0000-000000000001',
      '40000000-0000-0000-0000-000000000002'
    )$$,
  '42501',
  null,
  'Unauthorized user cannot insert a referral for Customer A'
);

reset role;
select throws_ok(
  $$insert into public.contracts (
      organization_id, customer_id, created_by, contract_type_id, status
    ) values (
      '20000000-0000-0000-0000-000000000002',
      '40000000-0000-0000-0000-000000000001',
      '10000000-0000-0000-0000-000000000003',
      'a0000000-0000-0000-0000-000000000001', 'active'
    )$$,
  '23503',
  null,
  'J: Cross-organization contract relationship is rejected'
);
select throws_ok(
  $$insert into public.referrals (
      organization_id, referrer_customer_id, referred_customer_id
    ) values (
      '20000000-0000-0000-0000-000000000001',
      '40000000-0000-0000-0000-000000000001',
      '40000000-0000-0000-0000-000000000001'
    )$$,
  '23514',
  null,
  'K: A customer cannot refer themselves'
);

set local role authenticated;
set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000002';
select throws_ok(
  $$insert into public.customers (
      organization_id, created_by, owner_id, first_name, last_name
    ) values (
      '20000000-0000-0000-0000-000000000001',
      '10000000-0000-0000-0000-000000000002',
      '10000000-0000-0000-0000-000000000001',
      'Forged', 'Owner'
    )$$,
  '42501',
  null,
  'L: Agent cannot create a customer owned by another user'
);
select throws_ok(
  $$insert into public.customers (
      organization_id, created_by, owner_id, first_name, last_name
    ) values (
      '20000000-0000-0000-0000-000000000001',
      '10000000-0000-0000-0000-000000000001',
      '10000000-0000-0000-0000-000000000002',
      'Forged', 'Creator'
    )$$,
  '42501',
  null,
  'L: Agent cannot forge created_by'
);

reset role;
set local role anon;
set local request.jwt.claim.sub = '';
select throws_ok(
  $$select * from public.customers$$,
  '42501',
  null,
  'M: Anonymous users have no customer table privilege'
);
select throws_ok(
  $$select * from public.contracts$$,
  '42501',
  null,
  'M: Anonymous users have no contract table privilege'
);
select throws_ok(
  $$select * from public.follow_ups$$,
  '42501',
  null,
  'M: Anonymous users have no follow-up table privilege'
);
select throws_ok(
  $$select * from public.notes$$,
  '42501',
  null,
  'M: Anonymous users have no notes table privilege'
);
select throws_ok(
  $$select * from public.referrals$$,
  '42501',
  null,
  'M: Anonymous users have no referral table privilege'
);

reset role;
insert into public.contracts (
  id, organization_id, customer_id, created_by, contract_type_id, status
) values (
  '50000000-0000-0000-0000-000000000002',
  '20000000-0000-0000-0000-000000000001',
  '40000000-0000-0000-0000-000000000002',
  '10000000-0000-0000-0000-000000000001',
  'a0000000-0000-0000-0000-000000000001', 'active'
);
select throws_ok(
  $$insert into public.follow_ups (
      organization_id, customer_id, contract_id, assigned_to, created_by, due_at, type, status
    ) values (
      '20000000-0000-0000-0000-000000000001',
      '40000000-0000-0000-0000-000000000001',
      '50000000-0000-0000-0000-000000000002',
      '10000000-0000-0000-0000-000000000001',
      '10000000-0000-0000-0000-000000000001',
      now(), 'renewal', 'not_started'
    )$$,
  '23503',
  null,
  'N: Follow-up cannot reference a contract for another customer'
);
select throws_ok(
  $$insert into public.notes (
      organization_id, customer_id, contract_id, created_by, content
    ) values (
      '20000000-0000-0000-0000-000000000001',
      '40000000-0000-0000-0000-000000000001',
      '50000000-0000-0000-0000-000000000002',
      '10000000-0000-0000-0000-000000000001',
      'Mismatched contract'
    )$$,
  '23503',
  null,
  'N: Note cannot reference a contract for another customer'
);

select ok(
  (select relrowsecurity from pg_class where oid = 'public.organizations'::regclass)
  and (select relrowsecurity from pg_class where oid = 'public.profiles'::regclass)
  and (select relrowsecurity from pg_class where oid = 'public.organization_members'::regclass)
  and (select relrowsecurity from pg_class where oid = 'public.customers'::regclass)
  and (select relrowsecurity from pg_class where oid = 'public.contracts'::regclass)
  and (select relrowsecurity from pg_class where oid = 'public.follow_ups'::regclass)
  and (select relrowsecurity from pg_class where oid = 'public.referrals'::regclass)
  and (select relrowsecurity from pg_class where oid = 'public.notes'::regclass),
  'RLS is enabled on every exposed application table'
);

select * from finish();
rollback;
