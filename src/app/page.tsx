import styles from "./page.module.css";

export default function Home() {
  return (
    <div className={styles.page}>
      <main className={styles.main}>
        <div className={styles.intro}>
          <h1>DealCheckers CRM</h1>
          <p>Technical foundation initialized. CRM features have not been built.</p>
        </div>
      </main>
    </div>
  );
}
