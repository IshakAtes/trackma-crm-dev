import styles from "./page.module.css";

export default function Home() {
  return (
    <div className={styles.page}>
      <main className={styles.main}>
        <div className={styles.intro}>
          <h1>trackma</h1>
          <p>Customer and contract management, built on a secure multi-tenant core.</p>
        </div>
      </main>
    </div>
  );
}
