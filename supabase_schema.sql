-- مخطط مجتمع أَثَر: الحسابات والمنشورات والإعجابات والتعليقات والرسائل الخاصة والبلاغات.
-- شغّل الملف كاملًا في Supabase > SQL Editor، ثم فعّل Email Auth من إعدادات Authentication.
create extension if not exists pgcrypto;

create table if not exists public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  handle text not null unique check (handle ~ '^[a-z0-9_]{3,24}$'),
  display_name text not null default 'زائر أَثَر' check (char_length(display_name) between 1 and 32),
  created_at timestamptz not null default now()
);
alter table public.profiles enable row level security;
drop policy if exists "profiles readable by signed in users" on public.profiles;
create policy "profiles readable by signed in users" on public.profiles for select to authenticated using (true);
drop policy if exists "insert own profile" on public.profiles;
create policy "insert own profile" on public.profiles for insert to authenticated with check (auth.uid() = user_id);
drop policy if exists "update own profile" on public.profiles;
create policy "update own profile" on public.profiles for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);

create table if not exists public.posts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  display_name text not null default 'زائر أَثَر' check (char_length(display_name) between 1 and 32),
  category text not null check (category in ('خاطرة','فائدة','سؤال','دعاء')),
  content text not null check (char_length(content) between 3 and 1200),
  created_at timestamptz not null default now(),
  is_hidden boolean not null default false
);
create index if not exists posts_created_at_idx on public.posts(created_at desc);
alter table public.posts enable row level security;
drop policy if exists "read visible posts" on public.posts;
create policy "read visible posts" on public.posts for select to authenticated using (is_hidden = false);
drop policy if exists "insert own posts" on public.posts;
create policy "insert own posts" on public.posts for insert to authenticated with check (auth.uid() = user_id);
drop policy if exists "delete own posts" on public.posts;
create policy "delete own posts" on public.posts for delete to authenticated using (auth.uid() = user_id);

create table if not exists public.post_likes (
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id,user_id)
);
alter table public.post_likes enable row level security;
drop policy if exists "read post likes" on public.post_likes;
create policy "read post likes" on public.post_likes for select to authenticated using (true);
drop policy if exists "like as self" on public.post_likes;
create policy "like as self" on public.post_likes for insert to authenticated with check (auth.uid() = user_id);
drop policy if exists "unlike as self" on public.post_likes;
create policy "unlike as self" on public.post_likes for delete to authenticated using (auth.uid() = user_id);

create table if not exists public.post_comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  display_name text not null default 'زائر أَثَر' check (char_length(display_name) between 1 and 32),
  content text not null check (char_length(content) between 1 and 500),
  created_at timestamptz not null default now()
);
create index if not exists post_comments_post_created_idx on public.post_comments(post_id,created_at);
alter table public.post_comments enable row level security;
drop policy if exists "read post comments" on public.post_comments;
create policy "read post comments" on public.post_comments for select to authenticated using (true);
drop policy if exists "insert own comments" on public.post_comments;
create policy "insert own comments" on public.post_comments for insert to authenticated with check (auth.uid() = user_id);
drop policy if exists "delete own comments" on public.post_comments;
create policy "delete own comments" on public.post_comments for delete to authenticated using (auth.uid() = user_id);

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references auth.users(id) on delete cascade,
  recipient_id uuid not null references auth.users(id) on delete cascade,
  content text not null check (char_length(content) between 1 and 2000),
  is_read boolean not null default false,
  created_at timestamptz not null default now(),
  check (sender_id <> recipient_id)
);
create index if not exists messages_inbox_idx on public.messages(recipient_id,created_at desc);
create index if not exists messages_outbox_idx on public.messages(sender_id,created_at desc);
alter table public.messages enable row level security;
drop policy if exists "read own messages" on public.messages;
create policy "read own messages" on public.messages for select to authenticated using (auth.uid() = sender_id or auth.uid() = recipient_id);
drop policy if exists "send messages as self" on public.messages;
create policy "send messages as self" on public.messages for insert to authenticated with check (auth.uid() = sender_id and sender_id <> recipient_id);
drop policy if exists "recipient marks message read" on public.messages;
create policy "recipient marks message read" on public.messages for update to authenticated using (auth.uid() = recipient_id) with check (auth.uid() = recipient_id);
create or replace function public.guard_message_update() returns trigger language plpgsql as $$
begin
  if new.id is distinct from old.id or new.sender_id is distinct from old.sender_id or new.recipient_id is distinct from old.recipient_id or new.content is distinct from old.content or new.created_at is distinct from old.created_at then
    raise exception 'Only read status can be updated';
  end if;
  return new;
end;
$$;
drop trigger if exists messages_update_guard on public.messages;
create trigger messages_update_guard before update on public.messages for each row execute function public.guard_message_update();

create table if not exists public.post_reports (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts(id) on delete cascade,
  reporter_id uuid not null references auth.users(id) on delete cascade,
  reason text not null check (char_length(reason) between 1 and 300),
  created_at timestamptz not null default now(),
  unique (post_id, reporter_id)
);
alter table public.post_reports enable row level security;
drop policy if exists "report as self" on public.post_reports;
create policy "report as self" on public.post_reports for insert to authenticated with check (auth.uid() = reporter_id);

-- لا تضع service_role key في الواجهة. راجع البلاغات من لوحة Supabase.


-- بلاغات الرسائل الخاصة: البلاغ لا يمنح أي مستخدم صلاحية قراءة رسائل الآخرين.
create table if not exists public.message_reports (
  id uuid primary key default gen_random_uuid(),
  message_id uuid not null references public.messages(id) on delete cascade,
  reporter_id uuid not null references auth.users(id) on delete cascade,
  reason text not null check (char_length(reason) between 1 and 300),
  created_at timestamptz not null default now(),
  unique (message_id, reporter_id)
);
alter table public.message_reports enable row level security;
drop policy if exists "report private message as self" on public.message_reports;
create policy "report private message as self" on public.message_reports for insert to authenticated with check (auth.uid() = reporter_id and exists (select 1 from public.messages m where m.id = message_id and (m.sender_id = auth.uid() or m.recipient_id = auth.uid())));
drop policy if exists "read own message reports" on public.message_reports;
create policy "read own message reports" on public.message_reports for select to authenticated using (auth.uid() = reporter_id);

-- أضف الرسائل إلى Realtime إذا لم تكن مضافة مسبقًا، لاستخدامه في تحديثات المحادثة مستقبلًا.
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'messages') then
    alter publication supabase_realtime add table public.messages;
  end if;
end $$;


-- طلبات حذف الحساب: تُراجع يدويًا من لوحة Supabase؛ لا تسمح الواجهة بحذف auth.users مباشرة.
create table if not exists public.account_deletion_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  account_email text,
  status text not null default 'pending' check (status in ('pending','reviewing','completed','rejected')),
  created_at timestamptz not null default now(),
  unique (user_id)
);
alter table public.account_deletion_requests enable row level security;
drop policy if exists "submit own account deletion request" on public.account_deletion_requests;
create policy "submit own account deletion request" on public.account_deletion_requests for insert to authenticated with check (auth.uid() = user_id);
drop policy if exists "read own account deletion request" on public.account_deletion_requests;
create policy "read own account deletion request" on public.account_deletion_requests for select to authenticated using (auth.uid() = user_id);
